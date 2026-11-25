import Foundation
import Testing
@testable import QuicksandCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// Run qs.bash's own parse_args on `args` and describe the outcome the way
/// `describe` describes a Swift parse.
private func bashParse(_ args: [String], quicksandArgs: String? = nil) throws -> String {
    let script = #"""
    source "$QS_BASH_UNDER_TEST"
    parse_args "$@"
    printf '%s\n' "command=$COMMAND" "sandbox=$SANDBOX_NAME" "dir=$INITIAL_DIR" \
        "clone=$CLONE_SOURCE" "gh=$GH_AUTH_REPO" "memory=$MEMORY_REPO" \
        "docker=$DOCKER_ACTION" "ssh=$SSH_AUTH_ARG" "rebuild=$REBUILD" \
        "nobuild=$NO_BUILD" "sandboxed=$USE_SANDBOX" "write=$OP_WRITE" "verbose=$QS_VERBOSE"
    for p in ${GCP_TARGET_PROJECTS[@]+"${GCP_TARGET_PROJECTS[@]}"}; do printf 'project=%s\n' "$p"; done
    for a in ${COMMAND_ARGS[@]+"${COMMAND_ARGS[@]}"}; do printf 'arg=%s\n' "$a"; done
    """#
    let bash = Process()
    bash.executableURL = URL(fileURLWithPath: "/bin/bash")
    bash.arguments = ["-c", script, "bash"] + args
    var env = ProcessInfo.processInfo.environment
    env["QS_BASH_UNDER_TEST"] = repoRoot.appendingPathComponent("qs.bash").path
    env["QS_SESSION_ID"] = nil   // qs.bash refuses to load inside a sandbox
    env["QS_VERBOSE"] = nil
    env["QUICKSAND_ARGS"] = quicksandArgs
    bash.environment = env
    let out = Pipe(), err = Pipe()
    bash.standardOutput = out
    bash.standardError = err
    try bash.run()
    let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    bash.waitUntilExit()

    if bash.terminationStatus != 0 {
        // abort prints "ERROR: ..." (the ERR trap may add a line after it).
        let line = stderr.split(separator: "\n").first { $0.hasPrefix("ERROR: ") }
        return "failure: " + (line.map { String($0.dropFirst(7)) } ?? "exit \(bash.terminationStatus): \(stderr)")
    }
    return stdout
}

private func describe(_ parse: QsParse) -> String {
    switch parse {
    case .help: return "help"
    case .version: return "version"
    case .failure(let m): return "failure: " + m
    case .run(let a):
        var lines = ["command=\(a.command.rawValue)", "sandbox=\(a.sandbox)", "dir=\(a.initialDir)",
                     "clone=\(a.cloneSource)", "gh=\(a.ghAuthRepo)", "memory=\(a.memoryRepo)",
                     "docker=\(a.dockerAction)", "ssh=\(a.sshAuthArg)", "rebuild=\(a.rebuild)",
                     "nobuild=\(a.noBuild)", "sandboxed=\(a.useSandbox)", "write=\(a.opWrite)",
                     "verbose=\(a.verbose)"]
        lines += a.gcpProjects.map { "project=\($0)" }
        lines += a.passthrough.map { "arg=\($0)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

@Suite struct QsArgumentsTests {
    /// Every command, alias and option, the error paths, and the ordering
    /// rules — each must parse exactly as qs.bash parses it.
    static let commandLines: [[String]] = [
        [], ["-r"], ["--help"], ["-h", "nosuch"], ["--version"], ["shell", "foo", "--version"],
        ["-q", "--version"], ["--version", "-q"], ["nosuch"], ["-rv"], ["-"],
        ["list"], ["l"], ["list", "extra", "args"], ["-v", "list"],
        ["shell", "foo"], ["s", "foo", "~/sub/dir"], ["claude", "work", "repo"], ["cl", "work"],
        ["claude", "work", "--", "-p", "a b", "", "--", "-x"], ["-x", "-r", "-n", "shell", "foo"],
        ["shell", "foo", "-x"], ["shell"], ["shell", ""], ["shell", "bad name"],
        ["shell", "seventeen-chars-x"], ["shell", "sixteen-chars-xx"], ["shell", "dröm"],
        ["clone", "foo"], ["c", "foo", "git@github.com:me/x.git"],
        ["gh-auth", "foo"], ["g", "foo", "me/repo"],
        ["memory", "foo"], ["m", "foo", "me/mem"],
        ["gcp-auth", "foo"], ["gp", "foo", "p1", "p2", "p3"], ["gcp-token", "foo"], ["gt", "foo"],
        ["op-auth", "foo"], ["--write", "o", "foo"],
        ["docker", "foo"], ["d", "foo", "off"], ["docker", "foo", "on"], ["docker", "foo", "maybe"],
        ["ssh-auth", "foo"], ["sa", "foo", "off"], ["ssh-auth", "foo", "k.pub", "extra"],
        ["build", "foo", "-r"], ["b", "foo"], ["uninstall", "foo"], ["u", "foo"],
        ["-v", "build", "foo"], ["-vv", "-v", "--verbose", "build", "foo"], ["-vvv", "build", "foo"],
    ]

    @Test(arguments: commandLines)
    func parsesLikeQsBash(_ args: [String]) throws {
        let swift = QsCLI.parse(args), bash = try bashParse(args)
        let answeredBySwift: Bool
        switch swift {
        case .help, .version: answeredBySwift = true
        case .run(let a): answeredBySwift = a.command == .list
        case .failure: answeredBySwift = false
        }
        if answeredBySwift {
            // qs.bash no longer has these: the qs command answers them, and
            // qs.bash refuses them when run directly.
            #expect(bash.hasPrefix("failure: ") && bash.contains("is answered by the qs command"))
        } else {
            #expect(describe(swift) == bash)
        }
    }

    @Test func quicksandArgsGoFirstAndKeepQuotedSpaces() throws {
        let defaults = #"-x shell foo -- run "a b""#
        let swift = QsCLI.parse([], defaults: QsCLI.splitDefaults(defaults))
        #expect(describe(swift) == (try bashParse([], quicksandArgs: defaults)))
        guard case .run(let a) = swift else { Issue.record("expected run"); return }
        #expect(!a.useSandbox && a.passthrough == ["run", "a b"])

        let both = QsCLI.parse(["claude", "bar"], defaults: QsCLI.splitDefaults("-r"))
        #expect(describe(both) == (try bashParse(["claude", "bar"], quicksandArgs: "-r")))
    }

    @Test func splitsDefaultsWithShellRules() {
        #expect(QsCLI.splitDefaults("") == [])
        #expect(QsCLI.splitDefaults(#"-x  'a b' "c d" e\ f"#) == ["-x", "a b", "c d", "e f"])
    }

    @Test func versionMatchesQsBash() throws {
        // qs.bash's VERSION goes into every build's fingerprint.
        let script = try String(contentsOf: repoRoot.appendingPathComponent("qs.bash"), encoding: .utf8)
        #expect(script.contains("readonly VERSION=\"\(QsCLI.version)\"\n"))
    }

    @Test func helpCoversEveryCommandAndTheNameLimit() {
        for command in QsArguments.Command.allCases {
            #expect(QsCLI.helpText.contains("  qs \(command.rawValue)"), "help is missing \(command.rawValue)")
        }
        #expect(QsCLI.helpText.hasPrefix("quicksand \(QsCLI.version) — "))
        #expect(QsCLI.helpText.contains("Up to \(QsCLI.sandboxNameMaxLength) chars"))
    }
}

@Suite struct SandboxListTests {
    private func fixture() throws -> (homes: URL, shared: URL, install: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qs-list-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["homes/qs-work", "homes/qs-toy", "homes/not-a-sandbox", "homes/.qs-hidden",
                    "shared/qs-work/repos/proj", "shared/qs-work/repos/tools", "shared/qs-work/repos/.cache",
                    "shared/qs-work/memory/.git", "install"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        // A file named like a sandbox home isn't one.
        fm.createFile(atPath: root.appendingPathComponent("homes/qs-file").path, contents: Data())
        try "proj\tme/proj\t\ntools\t\t/l/tools\n".write(to: root.appendingPathComponent("install/clones-work"),
                                                         atomically: true, encoding: .utf8)
        try "agent-memory\tme/agent-memory\t\n".write(to: root.appendingPathComponent("install/memory-work"),
                                                       atomically: true, encoding: .utf8)
        return (root.appendingPathComponent("homes"), root.appendingPathComponent("shared"),
                root.appendingPathComponent("install"))
    }

    @Test func listsSandboxesWithClonesAndMemory() throws {
        let f = try fixture()
        #expect(SandboxList.render(homes: f.homes, shared: f.shared, installDir: f.install) == """
        Sandboxes:
          toy
          work
            proj (me/proj)
            tools
            memory (me/agent-memory)

        """)
    }

    @Test func saysSoWhenThereAreNone() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("qs-none-\(UUID().uuidString)")
        #expect(SandboxList.render(homes: empty, shared: empty, installDir: empty)
                == "Sandboxes:\n  (none — run 'qs build <NAME>')\n")
    }

    @Test func readsManifestsLikeBash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-mf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clones = dir.appendingPathComponent("clones")
        // The unterminated last line is skipped, as `while read` skips it.
        try "a\tme/a\t\nb\tme/b".write(to: clones, atomically: true, encoding: .utf8)
        #expect(SandboxList.ownerRepo(manifest: clones, entry: "a") == "me/a")
        #expect(SandboxList.ownerRepo(manifest: clones, entry: "b") == "")
        #expect(SandboxList.ownerRepo(manifest: clones, entry: "missing") == "")
        let memory = dir.appendingPathComponent("memory")
        // IFS=$'\t' read collapses runs of tabs.
        try "mem\t\tme/mem".write(to: memory, atomically: true, encoding: .utf8)
        #expect(SandboxList.memoryOwnerRepo(manifest: memory) == "me/mem")
    }
}
