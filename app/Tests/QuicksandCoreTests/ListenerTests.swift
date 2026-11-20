import Darwin
import Foundation
import Testing
@testable import QuicksandCore

/// End to end through a real socket: the test process plays the sandbox
/// (its own uid is mapped to a sandbox user) and the brokers are tiny bash
/// scripts.
@Suite(.serialized) struct ListenerTests {
    let me = getuid()

    func listener(_ kind: BrokerKind, _ fx: Fixture, users: UserDirectory,
                  max: Int = 16, updates: Updates) -> BrokerListener {
        BrokerListener(kind: kind, paths: fx.paths, users: users, maxPerSandbox: max) { updates.add($0) }
    }

    @Test func spawnsTheSandboxesBrokerWithTheConnection() throws {
        let fx = try Fixture()
        try fx.installBroker(.say, sandbox: "work",
                             script: #"IFS= read -r line; echo "$GREETING $1 got:$line""#,
                             env: ["GREETING": "hello"])
        let updates = Updates()
        let l = listener(.say, fx, users: FakeUsers(byUID: [me: "qs-work"]), updates: updates)
        try l.start()
        defer { l.stop() }

        #expect(exchange(l.socketPath, "ping\n") == "hello work got:ping\n")
        let done = try #require(updates.wait {
            if case .finished = $0.outcome { return true } else { return false }
        })
        #expect(done.sandbox == "work")
        guard case .finished(_, let status) = done.outcome else { return }
        #expect(status == 0)
        #expect(done.ended != nil)
    }

    @Test func turnsAwayCallersThatArentSandboxes() throws {
        let fx = try Fixture()
        try fx.installBroker(.docker, sandbox: "work", script: "echo SHOULD-NOT-RUN")
        let updates = Updates()
        let l = listener(.docker, fx, users: FakeUsers(byUID: [me: "drinchev"]), updates: updates)
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, "{}\n"))
        #expect(reply.contains("only serves quicksand sandboxes"))
        #expect(reply.hasSuffix("@@qs-docker-exit:125@@\n"))
        #expect(!reply.contains("SHOULD-NOT-RUN"))
    }

    @Test func dockerOffMeansTheClientIsToldHowToEnableIt() throws {
        let fx = try Fixture()
        let updates = Updates()
        let l = listener(.docker, fx, users: FakeUsers(byUID: [me: "qs-work"]), updates: updates)
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, "{}\n"))
        #expect(reply.contains("qs docker work"))
        #expect(reply.hasSuffix("@@qs-docker-exit:125@@\n"))
    }

    @Test func capsConcurrentRequestsPerSandbox() throws {
        let fx = try Fixture()
        try fx.installBroker(.auth, sandbox: "work", script: "echo done")
        let updates = Updates()
        let l = listener(.auth, fx, users: FakeUsers(byUID: [me: "qs-work"]), max: 0, updates: updates)
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, "refresh\n"))
        #expect(reply.contains("too many concurrent auth requests"))
        #expect(!reply.contains("done"))
    }

    @Test func brokerSeesNoneOfTheAppsOtherDescriptors() throws {
        let fx = try Fixture()
        // An fd the app holds that is not marked close-on-exec.
        let leaked = open("/dev/null", O_RDONLY)
        defer { close(leaked) }
        try fx.installBroker(.say, sandbox: "work",
                             script: "if [ -e /dev/fd/\(leaked) ]; then echo LEAKED; else echo clean; fi")
        let updates = Updates()
        let l = listener(.say, fx, users: FakeUsers(byUID: [me: "qs-work"]), updates: updates)
        try l.start()
        defer { l.stop() }

        #expect(exchange(l.socketPath, nil) == "clean\n")
    }

    @Test func refusesAnUnsafeSocketDirectory() throws {
        let fx = try Fixture()
        try FileManager.default.createDirectory(at: fx.paths.socketDir, withIntermediateDirectories: true)
        chmod(fx.paths.socketDir.path, 0o777)
        let l = listener(.say, fx, users: FakeUsers(byUID: [:]), updates: Updates())
        #expect(throws: BrokerListener.ListenError.self) { try l.start() }
        #expect(!l.isListening)
    }

    @Test func leavesSomeoneElsesFileAtTheSocketPathAlone() throws {
        let fx = try Fixture()
        try FileManager.default.createDirectory(at: fx.paths.socketDir, withIntermediateDirectories: true)
        let path = fx.paths.socket(.say).path
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        let l = listener(.say, fx, users: FakeUsers(byUID: [:]), updates: Updates())
        #expect(throws: BrokerListener.ListenError.self) { try l.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

    @Test func replacesItsOwnStaleSocketAndCleansUp() throws {
        let fx = try Fixture()
        let first = listener(.say, fx, users: FakeUsers(byUID: [:]), updates: Updates())
        try first.start()
        // Simulate a crash: the socket file stays behind.
        let second = listener(.say, fx, users: FakeUsers(byUID: [:]), updates: Updates())
        try second.start()
        #expect(second.isListening)
        second.stop()
        #expect(!FileManager.default.fileExists(atPath: fx.paths.socket(.say).path))
        first.stop()
    }
}

/// The whole path with the real bash broker from config/: listener →
/// qs-docker-broker (staged like qs stages it) → stub docker → events.jsonl
/// → EventLogReader.
let jqPath = ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.enabled(if: jqPath != nil, "needs jq"))
struct RealBrokerTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func dockerRequestFlowsThroughTheRealBrokerIntoTheEventLog() throws {
        let jq = try #require(jqPath)
        let qsEvent = Self.repo.appendingPathComponent("app/.build/debug/qs-event")
        try #require(FileManager.default.isExecutableFile(atPath: qsEvent.path), "swift test builds qs-event")
        let fx = try Fixture()
        let fm = FileManager.default

        // Stage the broker host-side and give it a stub docker CLI.
        let staged = fx.paths.installDir.appendingPathComponent("docker-broker-work.sh")
        try fm.copyItem(at: Self.repo.appendingPathComponent("config/qs-docker-broker"), to: staged)
        chmod(staged.path, 0o755)
        let docker = fx.root.appendingPathComponent("docker")
        try "#!/bin/bash\necho \"DOCKER: $*\"\n".write(to: docker, atomically: true, encoding: .utf8)
        chmod(docker.path, 0o755)
        let workspace = fx.paths.workspace("work")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": BrokerKind.docker.label(for: "work"),
            "ProgramArguments": ["/bin/bash", staged.path, "work", workspace.path, docker.path, jq],
            // The broker logs under $HOME/.config/quicksand; keep it in the
            // fixture. The app passes qs-event from its bundle; here it's
            // the one `swift test` built.
            "EnvironmentVariables": ["HOME": fx.root.path, "QS_EVENT_BIN": qsEvent.path],
        ]
        let specURL = fx.paths.spec(.docker, sandbox: "work")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: specURL)
        chmod(specURL.path, 0o644)

        let l = BrokerListener(kind: .docker, paths: fx.paths,
                               users: FakeUsers(byUID: [getuid(): "qs-work"])) { _ in }
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, #"{"v":1,"verb":"pull","image":"node:20"}"# + "\n"))
        #expect(reply.contains("DOCKER: pull node:20"))
        #expect(reply.contains("@@qs-docker-exit:0@@"))

        let reader = EventLogReader(url: fx.root.appendingPathComponent(".config/quicksand/events.jsonl"))
        let deadline = Date().addingTimeInterval(5)
        while reader.events.isEmpty && Date() < deadline {
            reader.poll()
            usleep(20_000)
        }
        let event = try #require(reader.events.last)
        #expect(event.sandbox == "work")
        #expect(event.broker == "docker")
        #expect(event.verb == "pull")
        #expect(event.target == "node:20")
        #expect(event.result == "ok")
    }
}
