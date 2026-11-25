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

// MARK: - Marker files

@Suite struct MarkerTests {
    @Test func trustsOnlyAMarkerTheHostUserWrote() throws {
        let fx = try Fixture()
        let marker = fx.paths.dockerMarker("work").path
        #expect(checkOwnedFile(marker, ownerUID: getuid()) == .missing)
        FileManager.default.createFile(atPath: marker, contents: Data())
        chmod(marker, 0o644)
        #expect(checkOwnedFile(marker, ownerUID: getuid()) == .ok)
        chmod(marker, 0o664)
        guard case .unsafe = checkOwnedFile(marker, ownerUID: getuid()) else {
            Issue.record("group-writable marker accepted"); return
        }
        chmod(marker, 0o644)
        guard case .unsafe = checkOwnedFile(marker, ownerUID: getuid() + 1) else {
            Issue.record("marker owned by someone else accepted"); return
        }
        try FileManager.default.removeItem(atPath: marker)
        try FileManager.default.createSymbolicLink(atPath: marker, withDestinationPath: "/etc/hosts")
        guard case .unsafe = checkOwnedFile(marker, ownerUID: getuid()) else {
            Issue.record("symlinked marker accepted"); return
        }
    }

    @Test func spotsFilesFromTheOldBashBrokers() throws {
        let fx = try Fixture()
        var paths = fx.paths
        paths.launchAgentsDir = fx.root.appendingPathComponent("LaunchAgents")
        let names = paths.oldBrokerFiles("work").map(\.lastPathComponent)
        #expect(names.contains("com.quicksand.docker-broker.work.plist"))
        #expect(names.contains("auth-broker-work.sh"))
        #expect(paths.oldBrokerFiles("work").contains {
            $0.path.hasSuffix("LaunchAgents/com.quicksand.say-broker.work.plist")
        })
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
        // Docker on via the marker, plus a spec an old build left behind.
        fm.createFile(atPath: fx.paths.dockerMarker("alpha").path, contents: Data())
        try fm.createDirectory(at: fx.paths.installDir.appendingPathComponent("brokers"), withIntermediateDirectories: true)
        fm.createFile(atPath: fx.paths.installDir.appendingPathComponent("brokers/com.quicksand.docker-broker.alpha.plist").path,
                      contents: Data())

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
        #expect(alpha.dockerEnabled && !boxes[1].dockerEnabled)
        #expect(alpha.needsRebuild && !boxes[1].needsRebuild)
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

// MARK: - Notifications

@Suite struct NoticeTests {
    func conn(_ outcome: BrokerConnection.Outcome, sandbox: String? = "trading") -> BrokerConnection {
        BrokerConnection(id: UUID(), kind: .docker, sandbox: sandbox, uid: 610,
                         started: Date(), ended: nil, outcome: outcome)
    }

    @Test func everyRequestAnnouncesTheStartOnce() {
        let started = conn(.running(pid: 42))
        #expect(BrokerNotice.make(for: started, isNew: true, mode: .all)?.title == "trading → Docker")
        #expect(BrokerNotice.make(for: started, isNew: false, mode: .all) == nil)
        #expect(BrokerNotice.make(for: started, isNew: true, mode: .problems) == nil)
        // A clean finish adds nothing.
        #expect(BrokerNotice.make(for: conn(.finished(pid: 42, status: 0)), isNew: false, mode: .all) == nil)
    }

    @Test func problemsAreAnnouncedUnlessOff() {
        let refused = conn(.rejected("this socket only serves quicksand sandboxes"), sandbox: nil)
        let notice = BrokerNotice.make(for: refused, isNew: true, mode: .problems)
        #expect(notice?.title == "Refused uid 610 (not a sandbox) → Docker")
        #expect(notice?.body == "this socket only serves quicksand sandboxes")

        let failed = conn(.finished(pid: 42, status: 125 << 8))
        #expect(BrokerNotice.make(for: failed, isNew: false, mode: .problems)?.body
                == "The broker exited with status 125.")
        #expect(BrokerNotice.make(for: conn(.finished(pid: 42, status: 9)), isNew: false, mode: .all)?.body
                == "The broker was killed by a signal.")
        #expect(BrokerNotice.make(for: refused, isNew: true, mode: .off) == nil)
        #expect(BrokerNotice.make(for: failed, isNew: false, mode: .off) == nil)
    }
}

// MARK: - Event writer (qs-event)

@Suite struct EventWriterTests {
    func line(verb: String = "run", fields: [(String, Data)] = [], sandbox: String = "work") throws -> [String: Any] {
        let text = try EventWriter.line(broker: "docker", sandbox: Data(sandbox.utf8), verb: Data(verb.utf8),
                                        result: "ok", fields: fields,
                                        started: Date(timeIntervalSince1970: 100),
                                        now: Date(timeIntervalSince1970: 112))
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func writesWhatTheAppReads() throws {
        let text = try EventWriter.line(broker: "docker", sandbox: Data("work".utf8), verb: Data("pull".utf8),
                                        result: "ok", fields: [("exit", Data("0".utf8)), ("target", Data("node:20".utf8))],
                                        started: nil)
        let e = try #require(BrokerEvent.decode(line: Data(text.utf8)))
        #expect(e.sandbox == "work" && e.broker == "docker" && e.verb == "pull" && e.result == "ok")
        #expect(e.exit == 0 && e.target == "node:20")
        #expect(e.date != nil)
    }

    @Test func cleansWhatTheSandboxSent() throws {
        var raw = Data("hi ".utf8); raw.append(0xff); raw.append(Data(" \"there\" \\ \u{07}\u{1b}[31mdone".utf8))
        let e = try line(fields: [("target", raw)])
        #expect(e["target"] as? String == #"hi  "there" \ [31mdone"#)
        #expect(e["secs"] as? Int == 12)
    }

    @Test func leavesOutEmptyValuesAndNonNumericExits() throws {
        let e = try line(fields: [("reason", Data()), ("exit", Data("12; rm".utf8))])
        #expect(e["reason"] == nil && e["exit"] == nil)
        #expect(try line(fields: [("exit", Data("125".utf8))])["exit"] as? Int == 125)
    }

    @Test func refusesWhatOnlyABrokerBugWouldSend() {
        #expect(throws: EventWriter.UsageError.badBroker("ssh")) {
            try EventWriter.line(broker: "ssh", sandbox: Data(), verb: Data(), result: "ok", fields: [], started: nil)
        }
        #expect(throws: EventWriter.UsageError.badField("sandbox")) {
            try EventWriter.line(broker: "say", sandbox: Data(), verb: Data(), result: "ok",
                                 fields: [("sandbox", Data("x".utf8))], started: nil)
        }
        #expect(throws: EventWriter.UsageError.badResult("OK!")) {
            try EventWriter.line(broker: "say", sandbox: Data(), verb: Data(), result: "OK!", fields: [], started: nil)
        }
    }

    @Test func rotatesOnceAndKeepsEveryLineUnderConcurrency() throws {
        let fx = try Fixture()
        let log = fx.paths.eventsLog
        let old = String(repeating: "x", count: 999) + "\n"
        try old.write(to: log, atomically: false, encoding: .utf8)
        // 40 writers at once; the old log is over the cap, the 40 new lines
        // (under 400 bytes) aren't: exactly one rotation, no line lost.
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            try? EventWriter.append("{\"n\":\(i)}", to: log, maxBytes: 500)
        }
        let rotated = try String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8)
        let current = try String(contentsOf: log, encoding: .utf8)
        #expect(rotated == old)
        #expect(Set(current.split(separator: "\n")).count == 40)
    }
}
