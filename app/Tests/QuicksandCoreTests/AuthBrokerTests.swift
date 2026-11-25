import Darwin
import Foundation
import Testing
@testable import QuicksandCore

/// The credential broker inside the app, through a real socket, with stub
/// providers in a temporary libexec/.
@Suite(.serialized) struct AuthBrokerTests {
    let me = getuid()

    final class Setup {
        let fx: Fixture
        let libexec: URL
        let priv: URL

        init() throws {
            fx = try Fixture()
            libexec = fx.root.appendingPathComponent("libexec")
            priv = fx.paths.privateDir("work")
            try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: priv, withIntermediateDirectories: true)
            let marker = fx.paths.installMarker("work").path
            FileManager.default.createFile(atPath: marker, contents: Data("fp\n".utf8))
            chmod(marker, 0o644)
        }

        func provider(_ name: String, _ body: String) throws {
            let url = libexec.appendingPathComponent("qs-auth-\(name)")
            try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }

        func broker(timeout: TimeInterval = 10, libexec: URL? = nil) -> AuthBroker {
            AuthBroker(paths: fx.paths, libexec: libexec ?? self.libexec,
                       hostPath: { "/opt/test/bin:/usr/bin:/bin" }, providerTimeout: timeout)
        }

        var events: [BrokerEvent] {
            let text = (try? String(contentsOf: fx.paths.eventsLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { BrokerEvent.decode(line: Data($0.utf8)) }
        }
    }

    func run(_ s: Setup, _ broker: AuthBroker, request: String, user: String = "qs-work") throws
        -> (reply: String?, done: BrokerConnection?) {
        let updates = Updates()
        let l = BrokerListener(kind: .auth, paths: s.fx.paths, users: FakeUsers(byUID: [me: user]),
                               inProcess: broker) { updates.add($0) }
        try l.start()
        defer { l.stop() }
        let reply = exchange(l.socketPath, request)
        let done = updates.wait(timeout: 15) {
            switch $0.outcome {
            case .finished, .rejected: return true
            case .running: return false
            }
        }
        return (reply, done)
    }

    @Test func runsEveryProvidersRefreshWithTheQsEnvironment() throws {
        let s = try Setup()
        try s.provider("one", #"echo "$1 $QS_SANDBOX_NAME $QS_PRIVATE_DIR $QS_INSTALL_DIR $QS_VERBOSE $PATH" > "$QS_PRIVATE_DIR/one""#)
        try s.provider("two", #"echo "$1" > "$QS_PRIVATE_DIR/two""#)
        let (reply, done) = try run(s, s.broker(), request: "refresh\n")

        #expect(reply == "done\n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 0))
        #expect(try String(contentsOf: s.priv.appendingPathComponent("one"), encoding: .utf8)
                == "refresh work \(s.priv.path) \(s.fx.paths.installDir.path) 0 /opt/test/bin:/usr/bin:/bin\n")
        #expect(try String(contentsOf: s.priv.appendingPathComponent("two"), encoding: .utf8) == "refresh\n")
        let event = try #require(s.events.last)
        #expect(event.broker == "auth" && event.verb == "refresh" && event.result == "ok")
        #expect(event.providers == "one=ok,two=ok")
    }

    @Test func relaysMessagesAndCompletesWhenAProviderFails() throws {
        let s = try Setup()
        try s.provider("aaa", #"echo "WARNING: unlock 1Password" >&2; printf 'x\033[2Jy\n'; exit 3"#)
        try s.provider("bbb", #"echo "Refreshing GCP access token...""#)
        let (reply, done) = try run(s, s.broker(), request: "refresh\n")

        #expect(reply == "WARNING: unlock 1Password\nx[2Jy\nRefreshing GCP access token...\ndone\n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 1 << 8))
        let event = try #require(s.events.last)
        #expect(event.result == "error")
        #expect(event.providers == "aaa=exit 3,bbb=ok")
    }

    @Test func acceptsNoRequestButRefresh() throws {
        let s = try Setup()
        try s.provider("one", #"touch "$QS_PRIVATE_DIR/ran""#)
        for request in ["refresh; rm -rf /\n", "provision\n", "\n"] {
            let (reply, _) = try run(s, s.broker(), request: request)
            #expect(reply == "qs-auth-broker: unknown request\n")
        }
        #expect(!FileManager.default.fileExists(atPath: s.priv.appendingPathComponent("ran").path))
        let event = try #require(s.events.first)
        #expect(event.result == "rejected" && event.verb == "refresh; rm -rf /")
        #expect(event.reason == "unknown request")
    }

    @Test func givesUpOnABlockingProviderAndStopsWhatItStarted() throws {
        let s = try Setup()
        try s.provider("slow", #"sleep 30 & echo $! > "$QS_PRIVATE_DIR/child"; wait"#)
        try s.provider("zzz", #"touch "$QS_PRIVATE_DIR/next-ran""#)
        let start = Date()
        let (reply, _) = try run(s, s.broker(timeout: 1), request: "refresh\n")

        #expect(Date().timeIntervalSince(start) < 8)
        let text = try #require(reply)
        #expect(text.contains("slow credential refresh gave up after 1s"))
        #expect(text.hasSuffix("done\n"))
        #expect(FileManager.default.fileExists(atPath: s.priv.appendingPathComponent("next-ran").path))
        // The provider's own child went with it (its process group was stopped).
        let child = try String(contentsOf: s.priv.appendingPathComponent("child"), encoding: .utf8)
        let pid = try #require(pid_t(child.trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(200_000)
        #expect(kill(pid, 0) == -1)
        #expect(s.events.last?.providers == "slow=timeout,zzz=ok")
    }

    @Test func aRequestDuringARefreshSharesIt() throws {
        let s = try Setup()
        try s.provider("one", #"echo run >> "$QS_PRIVATE_DIR/runs"; sleep 1"#)
        let broker = s.broker()
        let updates = Updates()
        let l = BrokerListener(kind: .auth, paths: s.fx.paths, users: FakeUsers(byUID: [me: "qs-work"]),
                               inProcess: broker) { updates.add($0) }
        try l.start()
        defer { l.stop() }

        var replies: [String?] = [nil, nil]
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { replies[0] = exchange(l.socketPath, "refresh\n") }
        usleep(300_000)
        DispatchQueue.global().async(group: group) { replies[1] = exchange(l.socketPath, "refresh\n") }
        group.wait()

        #expect(replies[0] == "done\n" && replies[1] == "done\n")
        #expect(try String(contentsOf: s.priv.appendingPathComponent("runs"), encoding: .utf8) == "run\n")
        #expect(Set(s.events.map(\.result)) == ["ok", "shared"])
    }

    @Test func saysSoWhenTheProvidersAreMissing() throws {
        let s = try Setup()
        let (reply, done) = try run(s, s.broker(libexec: s.fx.root.appendingPathComponent("nowhere")),
                                    request: "refresh\n")
        let text = try #require(reply)
        #expect(text.contains("auth providers were not found"))
        #expect(!text.contains("done"))
        #expect(try #require(done).outcome == .finished(pid: nil, status: 1 << 8))
    }

    @Test func refusesSandboxesThatArentBuilt() throws {
        let s = try Setup()
        try FileManager.default.removeItem(at: s.fx.paths.installMarker("work"))
        let (_, done) = try run(s, s.broker(), request: "refresh\n")
        guard case .rejected(let why) = try #require(done).outcome else { Issue.record("expected refusal"); return }
        #expect(why.contains("qs build work"))
    }

    @Test func repliesAreCleanAndCapped() {
        #expect(AuthBroker.replyLine("a\u{7}b\tc") == Data("abc\n".utf8))
        #expect(AuthBroker.replyLine(String(repeating: "x", count: 900)).count == 501)
    }

    @Test func asksTheLoginShellForItsPath() {
        let path = HostEnvironment.askShell("/bin/sh", flags: [], timeout: 5)
        #expect(path == ProcessInfo.processInfo.environment["PATH"])
        #expect(HostEnvironment.askShell("/nonexistent/shell", flags: ["-l"], timeout: 1) == nil)
        #expect(HostEnvironment.loginShellPath(shell: "/nonexistent/shell", timeout: 1) == HostEnvironment.fallbackPath)
    }
}
