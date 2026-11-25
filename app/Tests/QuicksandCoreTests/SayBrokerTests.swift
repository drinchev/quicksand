import Darwin
import Foundation
import Testing
@testable import QuicksandCore

/// Records what it was asked to say instead of speaking (the sandbox has no
/// speech services; the real voice is checked on the host).
final class FakeSpeaker: Speaker, @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    let succeeds: Bool

    init(succeeds: Bool = true) { self.succeeds = succeeds }

    func speak(_ text: String, timeout: TimeInterval) -> Bool {
        lock.withLock { said.append(text) }
        return succeeds
    }

    var spoken: [String] { lock.withLock { said } }
}

/// The speech broker inside the app, through a real socket, with a fake
/// speaker.
@Suite(.serialized) struct SayBrokerTests {
    let me = getuid()

    func markBuilt(_ fx: Fixture, _ sandbox: String) {
        FileManager.default.createFile(atPath: fx.paths.installMarker(sandbox).path, contents: Data("fp\n".utf8))
        chmod(fx.paths.installMarker(sandbox).path, 0o644)
    }

    func run(_ fx: Fixture, speaker: FakeSpeaker, request: String?, user: String = "qs-work") throws
        -> (reply: String?, done: BrokerConnection?) {
        let updates = Updates()
        let broker = SayBroker(paths: fx.paths, speaker: speaker)
        let l = BrokerListener(kind: .say, paths: fx.paths, users: FakeUsers(byUID: [me: user]),
                               broker: broker) { updates.add($0) }
        try l.start()
        defer { l.stop() }
        let reply = exchange(l.socketPath, request)
        let done = updates.wait {
            switch $0.outcome {
            case .finished, .rejected: return true
            case .running: return false
            }
        }
        return (reply, done)
    }

    func events(_ fx: Fixture) -> [BrokerEvent] {
        let text = (try? String(contentsOf: fx.paths.eventsLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { BrokerEvent.decode(line: Data($0.utf8)) }
    }

    @Test func speaksTheFirstLineAsPlainTextAndLogsIt() throws {
        let fx = try Fixture()
        markBuilt(fx, "work")
        let speaker = FakeSpeaker()
        let (reply, done) = try run(fx, speaker: speaker, request: "-v Zarvox --rm -rf\nignored\n")

        #expect(reply == "")                    // nothing goes back to the client
        let finished = try #require(done)
        #expect(finished.outcome == .finished(pid: nil, status: 0))
        #expect(speaker.spoken == ["-v Zarvox --rm -rf"])
        let event = try #require(events(fx).last)
        #expect(event.broker == "say" && event.sandbox == "work" && event.verb == "say")
        #expect(event.result == "ok")
        #expect(event.target == "-v Zarvox --rm -rf")
    }

    @Test func aSandboxThatIsntBuiltIsRefused() throws {
        let fx = try Fixture()
        let speaker = FakeSpeaker()
        let (_, done) = try run(fx, speaker: speaker, request: "hello\n")
        guard case .rejected(let why) = try #require(done).outcome else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("qs build work"))
        #expect(speaker.spoken.isEmpty)
    }

    @Test func callersThatArentSandboxesAreRefused() throws {
        let fx = try Fixture()
        let speaker = FakeSpeaker()
        let (_, done) = try run(fx, speaker: speaker, request: "hello\n", user: "drinchev")
        guard case .rejected = try #require(done).outcome else { Issue.record("expected a refusal"); return }
        #expect(speaker.spoken.isEmpty)
    }

    @Test func speechThatFailsIsAnErrorEvent() throws {
        let fx = try Fixture()
        markBuilt(fx, "work")
        let (_, done) = try run(fx, speaker: FakeSpeaker(succeeds: false), request: "hello\n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 1 << 8))
        let event = try #require(events(fx).last)
        #expect(event.result == "error")
        #expect(event.reason == "not spoken")
    }

    @Test func blankRequestsSayNothing() throws {
        let fx = try Fixture()
        markBuilt(fx, "work")
        let speaker = FakeSpeaker()
        let (_, done) = try run(fx, speaker: speaker, request: "   \u{7}\t \n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 0))
        #expect(speaker.spoken.isEmpty)
        #expect(events(fx).isEmpty)
    }

    @Test func cleansTheMessage() {
        // Control bytes go (escape sequences lose their ESC and BEL).
        #expect(SayBroker.message(from: Data("hi\u{1b}]0;pwned\u{7} there\t!".utf8))
                == Data("hi]0;pwned there!".utf8))
        // Capped at 300 bytes.
        #expect(SayBroker.message(from: Data(repeating: UInt8(ascii: "x"), count: 400)).count == 300)
        // …without cutting a character in half: 299 x's and a 2-byte é.
        let cut = SayBroker.message(from: Data((String(repeating: "x", count: 299) + "é").utf8))
        #expect(cut == Data(String(repeating: "x", count: 299).utf8))
        #expect(SayBroker.message(from: Data("   ".utf8)).isEmpty)
        #expect(SayBroker.message(from: Data()).isEmpty)
    }

    @Test func readsOnlyUpToTheLimitAndTheDeadline() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let client = BrokerClient(fd: fds[0])
        defer { close(fds[1]) }
        _ = "abcdef\nrest".withCString { write(fds[1], $0, 11) }
        #expect(client.readLine(maxBytes: 3, timeout: 1) == Data("abc".utf8))
        #expect(client.readLine(maxBytes: 100, timeout: 1) == Data("def".utf8))
        // "rest" has no newline and the peer stays open: the deadline ends it.
        let start = Date()
        #expect(client.readLine(maxBytes: 100, timeout: 0.3) == Data("rest".utf8))
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

/// The real speaker, with a stub in place of /usr/bin/say.
@Suite struct SayCommandSpeakerTests {
    /// A stub `say` that logs its argument count, its stdin and when it
    /// started and ended, then exits with `status` after `seconds`.
    func stub(exit status: Int = 0, sleep seconds: Double = 0) throws -> (say: String, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("log")
        let say = dir.appendingPathComponent("say")
        try """
        #!/bin/bash
        echo "start ARGS:$#" >> '\(log.path)'
        echo "text:$(cat)" >> '\(log.path)'
        sleep \(seconds)
        echo end >> '\(log.path)'
        exit \(status)
        """.write(to: say, atomically: true, encoding: .utf8)
        chmod(say.path, 0o755)
        return (say.path, log)
    }

    func lines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func givesSayTheTextOnStdinAndNoArguments() throws {
        let s = try stub()
        #expect(SayCommandSpeaker(command: s.say).speak("-v Zarvox hi", timeout: 10))
        #expect(lines(s.log) == ["start ARGS:0", "text:-v Zarvox hi", "end"])
    }

    @Test func aFailingSayIsNotSpoken() throws {
        let s = try stub(exit: 3)
        #expect(!SayCommandSpeaker(command: s.say).speak("hi", timeout: 10))
    }

    @Test func stopsASayThatRunsPastTheTimeout() throws {
        let s = try stub(sleep: 30)
        let start = Date()
        #expect(!SayCommandSpeaker(command: s.say).speak("hi", timeout: 0.5))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(!lines(s.log).contains("end"))
    }

    @Test func speaksOneMessageAtATime() throws {
        let s = try stub(sleep: 0.3)
        let speaker = SayCommandSpeaker(command: s.say)
        let group = DispatchGroup()
        for text in ["one", "two", "three"] {
            DispatchQueue.global().async(group: group) { _ = speaker.speak(text, timeout: 10) }
        }
        group.wait()
        let log = lines(s.log)
        #expect(log.count == 9)
        // Never two "start"s without an "end" between them.
        var open = 0
        for line in log {
            if line.hasPrefix("start") { open += 1 } else if line == "end" { open -= 1 }
            #expect(open <= 1)
        }
    }
}
