import Darwin
import Foundation
import Testing
@testable import QuicksandCore

/// A broker for listener tests: answers one line, or refuses whom it's told.
final class EchoBroker: InProcessBroker, @unchecked Sendable {
    let refuse: (String) -> String?
    init(refuse: @escaping (String) -> String? = { _ in nil }) { self.refuse = refuse }

    func refusal(for sandbox: String) -> String? { refuse(sandbox) }

    func serve(_ client: BrokerClient, sandbox: String) -> Int32 {
        let line = String(decoding: client.readLine(maxBytes: 100, timeout: 5), as: UTF8.self)
        client.write(Data("hello \(sandbox) got:\(line)\n".utf8))
        return 0
    }
}

/// End to end through a real socket: the test process plays the sandbox
/// (its own uid is mapped to a sandbox user).
@Suite(.serialized) struct ListenerTests {
    let me = getuid()

    func listener(_ kind: BrokerKind, _ fx: Fixture, users: UserDirectory, max: Int = 16,
                  broker: InProcessBroker = EchoBroker(), updates: Updates) -> BrokerListener {
        BrokerListener(kind: kind, paths: fx.paths, users: users, maxPerSandbox: max, broker: broker) { updates.add($0) }
    }

    @Test func handsTheSandboxesConnectionToTheBroker() throws {
        let fx = try Fixture()
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
        let updates = Updates()
        let l = listener(.docker, fx, users: FakeUsers(byUID: [me: "drinchev"]), updates: updates)
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, "{}\n"))
        #expect(reply.contains("only serves quicksand sandboxes"))
        #expect(reply.hasSuffix("@@qs-docker-exit:125@@\n"))
        #expect(!reply.contains("hello"))
    }

    @Test func aBrokersRefusalReachesTheClientInItsProtocol() throws {
        let fx = try Fixture()
        let updates = Updates()
        let l = listener(.docker, fx, users: FakeUsers(byUID: [me: "qs-work"]),
                         broker: DockerBroker(paths: fx.paths, hostPath: { "/usr/bin:/bin" }), updates: updates)
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, "{}\n"))
        #expect(reply.contains("qs docker work"))
        #expect(reply.hasSuffix("@@qs-docker-exit:125@@\n"))
    }

    @Test func capsConcurrentRequestsPerSandbox() throws {
        let fx = try Fixture()
        let updates = Updates()
        let l = listener(.auth, fx, users: FakeUsers(byUID: [me: "qs-work"]), max: 0, updates: updates)
        try l.start()
        defer { l.stop() }

        let reply = try #require(exchange(l.socketPath, "refresh\n"))
        #expect(reply.contains("too many concurrent auth requests"))
        #expect(!reply.contains("hello"))
    }

    @Test func writingAfterARefusalIsAnErrorNotASignal() throws {
        let fx = try Fixture()
        let l = listener(.say, fx, users: FakeUsers(byUID: [me: "drinchev"]), updates: Updates())
        try l.start()
        defer { l.stop() }

        // Read the whole refusal first: by then the app has closed its end,
        // which is the race CI hit (SIGPIPE killed the test process).
        let fd = try #require(connectUnix(path: l.socketPath))
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        while read(fd, &buf, buf.count) > 0 {}
        usleep(50_000)
        let written = [UInt8]("late\n".utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        #expect(written == -1)
        #expect(errno == EPIPE)
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
