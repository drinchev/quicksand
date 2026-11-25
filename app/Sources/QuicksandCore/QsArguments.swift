import Foundation

/// A parsed `qs` command line. Mirrors `parse_args` in qs.bash field for
/// field; a test runs both on the same inputs and requires identical results
/// while both exist.
public struct QsArguments: Equatable, Sendable {
    public enum Command: String, CaseIterable, Sendable {
        case list, shell, claude, clone, build, uninstall, memory, docker
        case ghAuth = "gh-auth", gcpAuth = "gcp-auth", gcpToken = "gcp-token"
        case opAuth = "op-auth", sshAuth = "ssh-auth"

        /// The short forms `qs` accepts (`qs cl NAME` is `qs claude NAME`).
        static let aliases: [String: Command] = [
            "l": .list, "s": .shell, "cl": .claude, "c": .clone, "g": .ghAuth,
            "m": .memory, "gp": .gcpAuth, "gt": .gcpToken, "o": .opAuth,
            "d": .docker, "sa": .sshAuth, "b": .build, "u": .uninstall,
        ]

        public init?(word: String) {
            if let c = Command(rawValue: word) ?? Command.aliases[word] { self = c } else { return nil }
        }

        var needsName: Bool { self != .list }
    }

    public var command: Command
    public var sandbox = ""
    /// `qs shell|claude NAME PATH`.
    public var initialDir = ""
    /// `qs clone NAME URL_OR_PATH`.
    public var cloneSource = ""
    /// `qs gh-auth NAME OWNER/REPO`.
    public var ghAuthRepo = ""
    /// `qs memory NAME OWNER/REPO`.
    public var memoryRepo = ""
    /// `qs gcp-auth NAME PROJECT...`.
    public var gcpProjects: [String] = []
    /// `qs docker NAME [off]`: "on" or "off".
    public var dockerAction = "on"
    /// `qs ssh-auth NAME [KEY.pub | off]`.
    public var sshAuthArg = ""
    public var rebuild = false
    public var noBuild = false
    public var useSandbox = true
    /// `qs op-auth NAME --write`.
    public var opWrite = false
    /// QS_VERBOSE plus each -v (-vv: 2, -vvv: 3).
    public var verbose = 0
    /// Everything after `--`, for the spawned shell.
    public var passthrough: [String] = []

    public init(command: Command) { self.command = command }
}

/// What a command line asks for.
public enum QsParse: Equatable, Sendable {
    case help
    case version
    case run(QsArguments)
    /// What qs.bash's `abort` prints after "ERROR: " (it exits 1).
    case failure(String)
}

public enum QsCLI {
    /// Must match VERSION in qs.bash, which goes into every build's
    /// fingerprint (a test compares them).
    public static let version = "0.1.0"
    public static let sandboxNameMaxLength = 16

    /// Parse like `parse_args`: options anywhere until `--`, processed left
    /// to right (so `--version` or `--help` wins over anything after it,
    /// and an unknown option before it wins over it); then COMMAND, NAME
    /// and the command's own arguments. `defaults` are QUICKSAND_ARGS,
    /// already split; they go first.
    public static func parse(_ arguments: [String], defaults: [String] = [], verbose: Int = 0) -> QsParse {
        var opts = QsArguments(command: .list)
        opts.verbose = verbose
        var words: [String] = []
        var rest = (defaults + arguments)[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--":
                opts.passthrough = Array(rest)
                rest = []
            case "-r", "--rebuild": opts.rebuild = true
            case "-n", "--no-build": opts.noBuild = true
            case "-x", "--no-sandbox": opts.useSandbox = false
            case "--write": opts.opWrite = true
            case "-v", "--verbose": opts.verbose += 1
            case "-vv": opts.verbose += 2
            case "-vvv": opts.verbose += 3
            case "--version": return .version
            case "-h", "--help": return .help
            case _ where arg.hasPrefix("-"): return .failure("Unknown option: \(arg)")
            default: words.append(arg)
            }
        }

        guard let first = words.first else { return .help }
        guard let command = QsArguments.Command(word: first) else {
            return .failure("Unknown command: \(first) (try: qs --help)")
        }
        opts.command = command
        guard command.needsName else { return .run(opts) }

        guard words.count >= 2 else { return .failure("sandbox name required after '\(first)' (try: qs --help)") }
        if let problem = nameProblem(words[1]) { return .failure(problem) }
        opts.sandbox = words[1]
        let third = words.count >= 3 ? words[2] : nil

        switch command {
        case .shell, .claude:
            opts.initialDir = third ?? ""
        case .clone:
            guard let source = third else { return .failure("qs clone requires URL or local path (try: qs --help)") }
            opts.cloneSource = source
        case .ghAuth:
            opts.ghAuthRepo = third ?? ""
        case .memory:
            guard let repo = third else { return .failure("qs memory requires OWNER/REPO (try: qs --help)") }
            opts.memoryRepo = repo
        case .gcpAuth:
            opts.gcpProjects = Array(words.dropFirst(2))
        case .docker:
            opts.dockerAction = third ?? "on"
            guard opts.dockerAction == "on" || opts.dockerAction == "off" else {
                return .failure("qs docker accepts 'off' or nothing (got: \(opts.dockerAction))")
            }
        case .sshAuth:
            guard words.count <= 3 else {
                return .failure("qs ssh-auth takes one KEY.pub (or 'off') — quote a pasted key line")
            }
            opts.sshAuthArg = third ?? ""
        case .list, .build, .uninstall, .gcpToken, .opAuth:
            break
        }
        return .run(opts)
    }

    /// Why `name` can't be a sandbox name (validate_sandbox_name), or nil.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "sandbox name required" }
        let allowed = name.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        if !allowed { return "sandbox name must contain only letters, digits, '-' and '_' (got: \(name))" }
        if name.count > sandboxNameMaxLength {
            return "sandbox name must be \(sandboxNameMaxLength) characters or fewer (got \(name.count))"
        }
        return nil
    }

    /// Split QUICKSAND_ARGS with shell rules, exactly as qs.bash does: zsh's
    /// (z) tokenizes and (Q) strips one level of quotes. Empty words drop.
    public static func splitDefaults(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-fc", #"print -rl -- "${(@Q)${(z)1}}""#, "--", value]
        let out = Pipe()
        zsh.standardOutput = out
        zsh.standardError = FileHandle.nullDevice
        do { try zsh.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        zsh.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
