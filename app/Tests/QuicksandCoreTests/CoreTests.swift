import Darwin
import Foundation
import Testing
@testable import QuicksandCore

// MARK: - Identity

@Suite struct IdentityTests {
    @Test func sandboxNamesFollowQsRules() {
        #expect(SandboxName.isValid("trading"))
        #expect(SandboxName.isValid("reedy-a_1"))
        #expect(!SandboxName.isValid(""))
        #expect(!SandboxName.isValid("seventeen-chars-x"))
        #expect(!SandboxName.isValid("a/b"))
        #expect(!SandboxName.isValid("dröm"))
    }

    @Test func onlyQsUsersAreSandboxes() {
        #expect(SandboxName.from(username: "qs-trading") == "trading")
        #expect(SandboxName.from(username: "drinchev") == nil)
        #expect(SandboxName.from(username: "qs-") == nil)
        #expect(SandboxName.from(username: "qs-../x") == nil)
    }

    @Test func uidMustRoundTrip() {
        // A name that maps back to a different uid is not trusted.
        struct Skewed: UserDirectory {
            func username(forUID uid: uid_t) -> String? { "qs-work" }
            func uid(forUsername name: String) -> uid_t? { 4242 }
        }
        #expect(sandboxName(forUID: 501, users: Skewed()) == nil)
        #expect(sandboxName(forUID: 610, users: FakeUsers(byUID: [610: "qs-work"])) == "work")
        #expect(sandboxName(forUID: 501, users: FakeUsers(byUID: [501: "drinchev"])) == nil)
    }

    @Test func systemDirectoryKnowsTheCurrentUser() throws {
        let users = SystemUserDirectory()
        let name = try #require(users.username(forUID: getuid()))
        #expect(users.uid(forUsername: name) == getuid())
    }
}

// MARK: - Broker specs

@Suite struct BrokerSpecTests {
    @Test func loadsArgumentsAndEnvironment() throws {
        let fx = try Fixture()
        try fx.installBroker(.auth, sandbox: "work", script: "echo hi", env: ["QS_AUTH_LIBEXEC": "/x"])
        let spec = try BrokerSpec.load(.auth, sandbox: "work", paths: fx.paths).get()
        #expect(spec.arguments.count == 3)
        #expect(spec.arguments[2] == "work")
        #expect(spec.environment["QS_AUTH_LIBEXEC"] == "/x")
    }

    @Test func missingSpecMeansNotEnabled() throws {
        let fx = try Fixture()
        #expect(BrokerSpec.load(.docker, sandbox: "work", paths: fx.paths) == .failure(.missing))
    }

    @Test func refusesASpecForAnotherSandbox() throws {
        let fx = try Fixture()
        try fx.installBroker(.say, sandbox: "work", script: "true", label: "com.quicksand.say-broker.other")
        guard case .failure(.malformed) = BrokerSpec.load(.say, sandbox: "work", paths: fx.paths) else {
            Issue.record("label mismatch accepted"); return
        }
        try fx.installBroker(.say, sandbox: "work", script: "true",
                             args: ["/bin/bash", fx.paths.installDir.appendingPathComponent("say-broker-work.sh").path, "other"])
        guard case .failure(.malformed) = BrokerSpec.load(.say, sandbox: "work", paths: fx.paths) else {
            Issue.record("argument mismatch accepted"); return
        }
    }

    @Test func refusesFilesOthersCouldEdit() throws {
        let fx = try Fixture()
        let plist = try fx.installBroker(.say, sandbox: "work", script: "true")
        chmod(plist.path, 0o664)
        guard case .failure(.unsafe) = BrokerSpec.load(.say, sandbox: "work", paths: fx.paths) else {
            Issue.record("group-writable plist accepted"); return
        }
        chmod(plist.path, 0o644)
        chmod(fx.paths.installDir.appendingPathComponent("say-broker-work.sh").path, 0o775)
        guard case .failure(.unsafe) = BrokerSpec.load(.say, sandbox: "work", paths: fx.paths) else {
            Issue.record("group-writable broker script accepted"); return
        }
    }

    @Test func fallsBackToALaunchAgentUntilTheSandboxIsRebuilt() throws {
        let fx = try Fixture()
        var paths = fx.paths
        let agents = fx.root.appendingPathComponent("LaunchAgents")
        paths.legacySpecDir = agents
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

        // Only a pre-app LaunchAgent: served from it, and flagged.
        let rendered = try fx.installBroker(.say, sandbox: "work", script: "true")
        let legacy = agents.appendingPathComponent(rendered.lastPathComponent)
        try FileManager.default.moveItem(at: rendered, to: legacy)
        #expect(paths.spec(.say, sandbox: "work") == legacy)
        #expect(paths.usesLaunchAgent(.say, sandbox: "work"))
        #expect((try? BrokerSpec.load(.say, sandbox: "work", paths: paths).get()) != nil)

        // After a rebuild both exist until qs removes the old one; the new wins.
        try fx.installBroker(.say, sandbox: "work", script: "true")
        #expect(paths.spec(.say, sandbox: "work") == rendered)
        #expect(!paths.usesLaunchAgent(.say, sandbox: "work"))
        #expect(!paths.usesLaunchAgent(.docker, sandbox: "work"))
    }

    @Test func refusesASymlinkedSpec() throws {
        let fx = try Fixture()
        let real = try fx.installBroker(.say, sandbox: "work", script: "true")
        let moved = fx.root.appendingPathComponent("elsewhere.plist")
        try FileManager.default.moveItem(at: real, to: moved)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: moved)
        guard case .failure(.unsafe) = BrokerSpec.load(.say, sandbox: "work", paths: fx.paths) else {
            Issue.record("symlinked plist accepted"); return
        }
    }
}

// MARK: - Event log

@Suite struct EventTests {
    let ok = #"{"ts":"2026-11-20T09:14:03Z","sandbox":"trading","broker":"docker","verb":"run","result":"ok","secs":12,"exit":0,"target":"node:20"}"#
    let rejected = #"{"ts":"2026-11-20T09:15:40Z","sandbox":"trading","broker":"docker","verb":"run","result":"rejected","secs":0,"exit":125,"target":"--privileged","reason":"run: bad image ref"}"#
    let auth = #"{"ts":"2026-11-20T09:20:00Z","sandbox":"agent","broker":"auth","verb":"refresh","result":"error","secs":31,"providers":"gcp=ok,op=timeout"}"#

    @Test func decodesWhatTheBrokersWrite() throws {
        let e = try #require(BrokerEvent.decode(line: Data(rejected.utf8)))
        #expect(e.kind == .docker)
        #expect(e.isProblem)
        #expect(e.exit == 125)
        #expect(e.summary == "run --privileged")
        #expect(e.date == (try Date("2026-11-20T09:15:40Z", strategy: .iso8601)))
        let a = try #require(BrokerEvent.decode(line: Data(auth.utf8)))
        #expect(a.summary == "refresh gcp=ok,op=timeout")
    }

    @Test func readerFollowsAppendsPartialLinesAndRotation() throws {
        let fx = try Fixture()
        let url = fx.paths.eventsLog
        let reader = EventLogReader(url: url)
        #expect(!reader.poll())  // no file yet

        try "\(ok)\nnot json\n\(rejected.prefix(30))".write(to: url, atomically: false, encoding: .utf8)
        #expect(reader.poll())
        #expect(reader.events.count == 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(rejected.dropFirst(30))\n".utf8))
        try handle.close()
        #expect(reader.poll())
        #expect(reader.events.map(\.result) == ["ok", "rejected"])
        #expect(reader.events.map(\.seq) == [1, 2])

        // Rotation: the brokers move the file aside and start a new one.
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        try "\(auth)\n".write(to: url, atomically: false, encoding: .utf8)
        #expect(reader.poll())
        #expect(reader.events.last?.broker == "auth")
        #expect(reader.events.count == 3)
    }

    @Test func statsCountOnlyTheWindow() throws {
        let events = [ok, rejected, auth].compactMap { BrokerEvent.decode(line: Data($0.utf8)) }
        let since = try Date("2026-11-20T09:15:00Z", strategy: .iso8601)
        let stats = EventStats.summarize(events, since: since)
        #expect(stats.total == 2)
        #expect(stats.problems == 2)
        #expect(stats.byBroker == ["docker": 1, "auth": 1])
        #expect(stats.lastBySandbox["trading"]?.result == "rejected")
    }
}

// MARK: - Sandboxes

@Suite struct ScannerTests {
    @Test func reportsWhatTheHostCanSee() throws {
        let fx = try Fixture()
        let fm = FileManager.default
        for home in ["qs-alpha", "qs-beta", "someone"] {
            try fm.createDirectory(at: fx.paths.usersDir.appendingPathComponent(home), withIntermediateDirectories: true)
        }
        let sessions = fx.paths.privateDir("alpha").appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        fm.createFile(atPath: sessions.appendingPathComponent("\(getpid())").path, contents: nil)
        fm.createFile(atPath: sessions.appendingPathComponent("99999").path, contents: nil)
        fm.createFile(atPath: fx.paths.privateDir("alpha").appendingPathComponent("gcp-token").path, contents: nil)
        try fx.installBroker(.docker, sandbox: "alpha", script: "true")  // staged before the event log
        try fx.installBroker(.say, sandbox: "alpha", script: "# --- event log: keep this block identical\ntrue")

        let scanner = SandboxScanner(
            paths: fx.paths, users: FakeUsers(byUID: [700: "qs-alpha", 701: "qs-beta"]),
            listProcesses: { uid in
                // Both have the daemons any past login leaves behind; only alpha runs anything.
                let daemons = ["/usr/sbin/cfprefsd", "/usr/sbin/distnoted", "/usr/libexec/lsd",
                               "/System/Library/Frameworks/CoreServices.framework/mdbulkimport",
                               "/Users/qs-x/.local/bin/op",
                               "/Users/qs-x/.claude/remote/srv/13047a51/server"]
                return uid == 700 ? daemons + ["/bin/zsh", "/Users/qs-alpha/.local/bin/claude"] : daemons
            })
        let boxes = scanner.scan()
        #expect(boxes.map(\.name) == ["alpha", "beta"])
        let alpha = boxes[0]
        #expect(alpha.isActive)
        #expect(alpha.processes == ["claude", "zsh"])
        #expect(alpha.sessionCount == 1)  // our own pid is alive; 99999 isn't
        #expect(alpha.brokers == [.docker, .say])
        #expect(alpha.brokersWithoutEventLog == [.docker])
        #expect((alpha.gcpTokenAge ?? 999) < 60)
        #expect(!alpha.opTokenStaged)
        // Lingering system daemons alone don't make a sandbox active.
        #expect(!boxes[1].isActive && boxes[1].processes.isEmpty && boxes[1].uid == 701)
    }

    @Test func listsOurOwnProcesses() {
        let paths = ProcessTable.executables(uid: getuid())
        #expect(paths.contains { $0.hasSuffix("/swiftpm-testing-helper") || $0.contains("QuicksandPackageTests") || $0.hasSuffix("/xctest") })
    }

    @Test func systemDaemonsAreRecognised() {
        #expect(ProcessTable.isSystemDaemon("/usr/sbin/cfprefsd"))
        #expect(ProcessTable.isSystemDaemon("/usr/libexec/trustd"))
        #expect(!ProcessTable.isSystemDaemon("/bin/zsh"))
        #expect(!ProcessTable.isSystemDaemon("/usr/bin/ssh"))
        #expect(!ProcessTable.isSystemDaemon("/Users/qs-x/.local/bin/claude"))
        #expect(!ProcessTable.isActivity("/Users/qs-x/.local/bin/op"))
        #expect(!ProcessTable.isActivity("/Users/qs-x/.claude/remote/srv/13047a51/server"))
        #expect(ProcessTable.isActivity("/Users/qs-x/.claude/remote/ccd-cli/2.1.326-33e8fe5fd805"))
        #expect(ProcessTable.isActivity("/usr/bin/ssh"))
    }
}
