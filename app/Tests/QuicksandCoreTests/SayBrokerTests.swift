import Darwin
import Foundation
import Testing
@testable import QuicksandCore

/// The speech broker inside the app, through a real socket, with a stub
/// `say` that records its arguments and what it read on stdin.
@Suite(.serialized) struct SayBrokerTests {
    let me = getuid()

    /// A stub `say` writing "ARGS:<count>" and then its stdin to `out`.
    func stubSay(_ fx: Fixture, exit status: Int = 0) throws -> (say: URL, out: URL) {
        let out = fx.root.appendingPathComponent("said")
        let say = fx.root.appendingPathComponent("say")
        try """
        #!/bin/bash
        printf 'ARGS:%d\\n' "$#" >> '\(out.path)'
        cat >> '\(out.path)'
        exit \(status)
        """.write(to: say, atomically: true, encoding: .utf8)
        chmod(say.path, 0o755)
        return (say, out)
    }

    func markBuilt(_ fx: Fixture, _ sandbox: String) {
        FileManager.default.createFile(atPath: fx.paths.installMarker(sandbox).path, contents: Data("fp\n".utf8))
        chmod(fx.paths.installMarker(sandbox).path, 0o644)
    }

    func run(_ fx: Fixture, say: URL, request: String?, user: String = "qs-work") throws
        -> (reply: String?, done: BrokerConnection?) {
        let updates = Updates()
        let broker = SayBroker(paths: fx.paths, sayCommand: say.path)
        let l = BrokerListener(kind: .say, paths: fx.paths, users: FakeUsers(byUID: [me: user]),
                               inProcess: broker) { updates.add($0) }
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

    @Test func speaksTheLineOnStdinWithNoArgumentsAndLogsIt() throws {
        let fx = try Fixture()
        markBuilt(fx, "work")
        let stub = try stubSay(fx)
        let (reply, done) = try run(fx, say: stub.say, request: "-v Zarvox --rm -rf\nignored\n")

        #expect(reply == "")                    // nothing goes back to the client
        let finished = try #require(done)
        #expect(finished.outcome == .finished(pid: nil, status: 0))
        #expect(try String(contentsOf: stub.out, encoding: .utf8) == "ARGS:0\n-v Zarvox --rm -rf\n")
        let event = try #require(events(fx).last)
        #expect(event.broker == "say" && event.sandbox == "work" && event.verb == "say")
        #expect(event.result == "ok")
        #expect(event.target == "-v Zarvox --rm -rf")
    }

    @Test func aSandboxThatIsntBuiltIsRefused() throws {
        let fx = try Fixture()
        let stub = try stubSay(fx)
        let (_, done) = try run(fx, say: stub.say, request: "hello\n")
        guard case .rejected(let why) = try #require(done).outcome else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("qs build work"))
        #expect(!FileManager.default.fileExists(atPath: stub.out.path))
    }

    @Test func callersThatArentSandboxesAreRefused() throws {
        let fx = try Fixture()
        let stub = try stubSay(fx)
        let (_, done) = try run(fx, say: stub.say, request: "hello\n", user: "drinchev")
        guard case .rejected = try #require(done).outcome else { Issue.record("expected a refusal"); return }
        #expect(!FileManager.default.fileExists(atPath: stub.out.path))
    }

    @Test func aFailingSayIsAnErrorEvent() throws {
        let fx = try Fixture()
        markBuilt(fx, "work")
        let stub = try stubSay(fx, exit: 3)
        let (_, done) = try run(fx, say: stub.say, request: "hello\n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 1 << 8))
        let event = try #require(events(fx).last)
        #expect(event.result == "error")
        #expect(event.reason == "say failed")
    }

    @Test func blankRequestsSayNothing() throws {
        let fx = try Fixture()
        markBuilt(fx, "work")
        let stub = try stubSay(fx)
        let (_, done) = try run(fx, say: stub.say, request: "   \u{7}\t \n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 0))
        #expect(!FileManager.default.fileExists(atPath: stub.out.path))
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
