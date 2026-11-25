import Darwin
import Foundation
import Testing
@testable import QuicksandCore

// MARK: - Policy

@Suite struct DockerPolicyTests {
    let ws = "/Users/Shared/qs-work"

    /// A filesystem where everything under the workspace exists, `..` is
    /// collapsed, and `/ws/link` is a symlink out of it.
    func resolve(_ p: String) -> String? {
        let std = (p as NSString).standardizingPath
        if std.hasPrefix(ws + "/link") { return "/etc" + std.dropFirst((ws + "/link").count) }
        return std.hasPrefix("/") ? std : nil
    }

    func plan(_ json: String) -> Result<DockerPolicy.Plan, DockerPolicy.Refusal> {
        DockerPolicy.plan(Data(json.utf8), sandbox: "work", workspace: ws, resolve: resolve)
    }

    func refusal(_ json: String) -> String? {
        if case .failure(let r) = plan(json) { return r.message }
        return nil
    }

    @Test func runComposesTheHardenedTemplate() throws {
        let p = try plan(#"{"v":1,"verb":"run","image":"node:20","cmd":["node","-e","x"],"env":{"FOO":"bar baz"},"workdir":"/Users/Shared/qs-work/repos/p"}"#).get()
        #expect(p.arguments == [
            "run", "--rm", "-i", "--label", "quicksand.sandbox=work", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "512", "--memory", "4g", "--cpus", "4",
            "--network", "bridge", "-v", "\(ws):\(ws)", "-w", "\(ws)/repos/p", "-v", "\(ws)/_quicksand",
            "-e", "FOO=bar baz", "node:20", "node", "-e", "x"])
        #expect(p.streamsStdin && p.target == "node:20" && p.ownedID == nil)
        // No workdir: the workspace root.
        let bare = try plan(#"{"verb":"run","image":"alpine"}"#).get()
        #expect(bare.arguments.contains("-w") && bare.arguments[bare.arguments.firstIndex(of: "-w")! + 1] == ws)
    }

    @Test func workdirsMustResolveInsideTheWorkspace() {
        #expect(refusal(#"{"verb":"run","image":"alpine","workdir":"/Users/me"}"#) == "run: workdir must be under \(ws)")
        #expect(refusal(#"{"verb":"run","image":"alpine","workdir":"/Users/Shared/qs-work/../qs-other"}"#) != nil)
        #expect(refusal(#"{"verb":"run","image":"alpine","workdir":"/Users/Shared/qs-work/link/x"}"#) != nil)
        #expect(refusal(#"{"verb":"run","image":"alpine","workdir":"/Users/Shared/qs-workX"}"#) != nil)
    }

    @Test func clientValuesCanNeverBecomeOptions() {
        #expect(refusal(#"{"verb":"run","image":"--privileged"}"#) == "run: bad image ref")
        #expect(refusal(#"{"verb":"run","image":"-v/:/h"}"#) == "run: bad image ref")
        #expect(refusal(#"{"verb":"pull","image":"a b"}"#) == "pull: bad image ref")
        #expect(refusal(#"{"verb":"logs","id":"--follow"}"#) == "logs: bad container id")
        #expect(refusal(#"{"verb":"stop","id":"x;rm -rf /"}"#) == "stop: bad container id")
        #expect(refusal(#"{"verb":"run","image":"alpine","env":{"A-B":"x"}}"#) == "run: bad env name")
        #expect(refusal(#"{"verb":"run","image":"alpine","env":{"-e":"x"}}"#) == "run: bad env name")
        #expect(refusal(#"{"verb":"run","image":"alpine","env":{"A":1}}"#) == "run: bad env")
        #expect(refusal(#"{"verb":"run","image":"alpine","cmd":"sh -c x"}"#) == "run: bad cmd")
        #expect(refusal(#"{"verb":"run","image":"alpine","cmd":["sh",1]}"#) == "run: bad cmd")
        #expect(refusal(#"{"verb":"run","image":7}"#) == "run: bad image ref")
    }

    @Test func buildsStayInTheirNamespaceAndContext() throws {
        let ok = try plan(#"{"verb":"build","tag":"qs-work/app:1","context":"/Users/Shared/qs-work/repos/app","dockerfile":"/Users/Shared/qs-work/repos/app/Dockerfile.dev"}"#).get()
        #expect(ok.arguments == ["build", "--label", "quicksand.sandbox=work", "-t", "qs-work/app:1",
                                 "-f", "\(ws)/repos/app/Dockerfile.dev", "\(ws)/repos/app"])
        #expect(!ok.streamsStdin)
        #expect(refusal(#"{"verb":"build","tag":"node:20","context":"/Users/Shared/qs-work/repos/app"}"#)?
                    .hasPrefix("build: tag must live under qs-work/") == true)
        #expect(refusal(#"{"verb":"build","tag":"qs-other/x","context":"/Users/Shared/qs-work/repos/app"}"#) != nil)
        #expect(refusal(#"{"verb":"build","tag":"qs-work/x","context":"/Users/me"}"#) == "build: context must be under \(ws)")
        #expect(refusal(#"{"verb":"build","tag":"qs-work/x","context":"/Users/Shared/qs-work"}"#)?
                    .contains("not its root") == true)
        #expect(refusal(#"{"verb":"build","tag":"qs-work/x","context":"/Users/Shared/qs-work/_quicksand/bin"}"#)
                == "build: context must not be under _quicksand")
        #expect(refusal(#"{"verb":"build","tag":"qs-work/x","context":"/Users/Shared/qs-work/repos/a","dockerfile":"/tmp/D"}"#)
                == "build: dockerfile must be under \(ws)")
        #expect(refusal(#"{"verb":"build","context":"/Users/Shared/qs-work/repos/a"}"#) == "build: missing tag")
    }

    @Test func listingAndContainersAreScopedToTheSandbox() throws {
        #expect(try plan(#"{"verb":"ps"}"#).get().arguments == ["ps", "-a", "--filter", "label=quicksand.sandbox=work"])
        let logs = try plan(#"{"verb":"logs","id":"abc123"}"#).get()
        #expect(logs.arguments == ["logs", "abc123"] && logs.ownedID == "abc123")
        #expect(DockerPolicy.ownerQuery("abc123") == ["inspect", "-f", #"{{ index .Config.Labels "quicksand.sandbox" }}"#, "abc123"])
    }

    @Test func anythingElseIsRefused() {
        #expect(refusal(#"{"verb":"exec","id":"x"}"#) == "unknown verb 'exec' (allowed: run build pull ps logs stop)")
        #expect(refusal("not json") == "unparseable request")
        #expect(refusal(#"["run"]"#) == "unparseable request")
        #expect(refusal(#"{"verb":5}"#) == "unparseable request")
        #expect(refusal(#"{"verb":"pull"}"#) == "pull: missing image")
        let big = Data(#"{"verb":"ps","x":""#.utf8) + Data(repeating: UInt8(ascii: "a"), count: 70_000) + Data(#""}"#.utf8)
        guard case .failure(let r) = DockerPolicy.plan(big, sandbox: "work", workspace: ws, resolve: resolve) else {
            Issue.record("oversized request accepted"); return
        }
        #expect(r.message == "request too large")
    }
}

// MARK: - Broker, end to end with a stub docker

@Suite(.serialized) struct DockerBrokerTests {
    let me = getuid()

    final class Setup {
        let fx: Fixture
        let bin: URL
        let log: URL
        let workspace: URL

        init(enabled: Bool = true) throws {
            fx = try Fixture()
            bin = fx.root.appendingPathComponent("bin")
            log = fx.root.appendingPathComponent("docker.log")
            workspace = fx.paths.workspace("work")
            let fm = FileManager.default
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.createDirectory(at: workspace.appendingPathComponent("repos/p"), withIntermediateDirectories: true)
            if enabled {
                fm.createFile(atPath: fx.paths.dockerMarker("work").path, contents: Data())
                chmod(fx.paths.dockerMarker("work").path, 0o644)
            }
            // A stub docker: logs its arguments, PATH and open descriptors;
            // `inspect` prints the owner in ./owner; `run` echoes its stdin;
            // exits with the code in ./exit (default 0).
            try """
            #!/bin/bash
            printf 'ARG:%s\\n' "$@" >> '\(log.path)'
            echo "PATH:$PATH" >> '\(log.path)'
            for fd in 3 4 5 6 7 8 9; do [ -e /dev/fd/$fd ] && echo "LEAKED:$fd" >> '\(log.path)'; done
            if [ "$1" = inspect ]; then cat '\(bin.path)/owner' 2>/dev/null; exit 0; fi
            if [ "$1" = run ]; then echo "stdin:$(cat)"; fi
            echo "out:$1"
            exit "$(cat '\(bin.path)/exit' 2>/dev/null || echo 0)"
            """.write(to: bin.appendingPathComponent("docker"), atomically: true, encoding: .utf8)
            chmod(bin.appendingPathComponent("docker").path, 0o755)
        }

        func broker() -> DockerBroker {
            let path = "\(bin.path):/usr/bin:/bin"
            return DockerBroker(paths: fx.paths, hostPath: { path })
        }

        var logLines: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        var events: [BrokerEvent] {
            let text = (try? String(contentsOf: fx.paths.eventsLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { BrokerEvent.decode(line: Data($0.utf8)) }
        }
    }

    func run(_ s: Setup, _ request: String, broker: DockerBroker? = nil) throws -> (reply: String, done: BrokerConnection?) {
        let updates = Updates()
        let l = BrokerListener(kind: .docker, paths: s.fx.paths, users: FakeUsers(byUID: [me: "qs-work"]),
                               broker: broker ?? s.broker()) { updates.add($0) }
        try l.start()
        defer { l.stop() }
        let reply = try #require(exchange(l.socketPath, request))
        let done = updates.wait(timeout: 10) {
            switch $0.outcome {
            case .finished, .rejected: return true
            case .running: return false
            }
        }
        return (reply, done)
    }

    @Test func runsTheContainerWithTheRestOfTheConnectionAsStdin() throws {
        let s = try Setup()
        // An fd the app holds that is not marked close-on-exec.
        let leaked = open("/dev/null", O_RDONLY)
        defer { close(leaked) }
        let ws = DockerPolicy.resolvePath(s.workspace.path)!
        let (reply, done) = try run(s, #"{"v":1,"verb":"run","image":"node:20","cmd":["node"],"env":{"SECRET":"s3"},"workdir":"\#(ws)/repos/p"}"#
                                        + "\nhello from the sandbox\n")
        #expect(reply == "stdin:hello from the sandbox\nout:run\n\n@@qs-docker-exit:0@@\n")
        #expect(try #require(done).outcome == .finished(pid: nil, status: 0))
        let lines = s.logLines
        #expect(lines.contains("ARG:--cap-drop") && lines.contains("ARG:-w") && lines.contains("ARG:\(ws)/repos/p"))
        #expect(lines.contains("ARG:\(ws)/_quicksand"))
        #expect(!lines.contains { $0.hasPrefix("LEAKED:") })
        // Credential helpers next to the CLI are found.
        #expect(lines.contains { $0.hasPrefix("PATH:\(s.bin.path):") })
        // The event names the image, never the command or its environment.
        let event = try #require(s.events.last)
        #expect(event.verb == "run" && event.result == "ok" && event.exit == 0 && event.target == "node:20")
        let raw = try String(contentsOf: s.fx.paths.eventsLog, encoding: .utf8)
        #expect(!raw.contains("s3") && !raw.contains("\"node\""))
    }

    @Test func aFailingDockerCommandIsAnError() throws {
        let s = try Setup()
        try "3".write(to: s.bin.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
        let (reply, done) = try run(s, #"{"verb":"pull","image":"alpine"}"# + "\n")
        #expect(reply.hasSuffix("@@qs-docker-exit:3@@\n"))
        #expect(try #require(done).outcome == .finished(pid: nil, status: 3 << 8))
        #expect(s.events.last?.result == "error")
    }

    @Test func aPolicyRefusalIsLoggedWithWhatWasAttempted() throws {
        let s = try Setup()
        let (reply, _) = try run(s, #"{"verb":"run","image":"--privileged"}"# + "\n")
        #expect(reply == "qs-docker: run: bad image ref\n\n@@qs-docker-exit:125@@\n")
        #expect(s.logLines.isEmpty)
        let event = try #require(s.events.last)
        #expect(event.result == "rejected" && event.verb == "run" && event.target == "--privileged")
        #expect(event.reason == "run: bad image ref" && event.exit == 125)
    }

    @Test func touchesOnlyContainersTheSandboxCreated() throws {
        let s = try Setup()
        try "other\n".write(to: s.bin.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
        let (refused, _) = try run(s, #"{"verb":"stop","id":"abc"}"# + "\n")
        #expect(refused.contains("stop: no such container"))
        #expect(!s.logLines.contains("ARG:stop"))

        try "work\n".write(to: s.bin.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
        let (stopped, _) = try run(s, #"{"verb":"stop","id":"abc"}"# + "\n")
        #expect(stopped.hasSuffix("out:stop\n\n@@qs-docker-exit:0@@\n"))
    }

    @Test func noDockerOnTheHostIsAnError() throws {
        let s = try Setup()
        let broker = DockerBroker(paths: s.fx.paths, hostPath: { "/nonexistent" })
        let (reply, _) = try run(s, #"{"verb":"ps"}"# + "\n", broker: broker)
        #expect(reply.contains("docker CLI not found on the host"))
        #expect(reply.hasSuffix("@@qs-docker-exit:125@@\n"))
        #expect(s.events.last?.result == "error")
    }

    @Test func dockerOffIsRefusedWithHowToTurnItOn() throws {
        let s = try Setup(enabled: false)
        let (reply, done) = try run(s, #"{"verb":"ps"}"# + "\n")
        #expect(reply.contains("on the host, run: qs docker work"))
        #expect(reply.hasSuffix("@@qs-docker-exit:125@@\n"))
        guard case .rejected = try #require(done).outcome else { Issue.record("expected refusal"); return }
        #expect(s.logLines.isEmpty)
    }

    @Test func hostileVerbsStayValidJSONInTheLog() throws {
        let s = try Setup()
        _ = try run(s, #"{"verb":"x\"y\u001b[2J"}"# + "\n")
        let event = try #require(s.events.last)
        #expect(event.result == "rejected")
        #expect(event.verb == "x\"y[2J")
    }
}
