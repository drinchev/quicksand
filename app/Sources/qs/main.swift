// qs — the quicksand command. Swift parses the command line and answers
// --help, --version and `list` itself; every other command goes to the bash
// qs (qs.bash): this process replaces itself with `/bin/bash qs.bash ARGS...`
// — exec, not a child process, so the terminal, sudo prompts, Ctrl-C,
// interactive sessions and the exit code are exactly the bash script's.
// Commands move into Swift one at a time; see docs/quicksand-app.md.
import Darwin
import Foundation
import QuicksandCore

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

/// What qs.bash's `abort` does.
func abort(_ message: String) -> Never { fail("ERROR: \(message)", status: 1) }

/// Hand the command line to qs.bash, unchanged: the raw argv bytes (not
/// CommandLine.arguments, which repairs invalid UTF-8).
func runBash() -> Never {
    guard let script = LegacyCLI.locateScript(environment: ProcessInfo.processInfo.environment,
                                              executable: LegacyCLI.currentExecutable()) else {
        fail("qs: can't find \(LegacyCLI.scriptName) — reinstall Quicksand.app, or set QS_BASH to its path",
             status: 127)
    }
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(LegacyCLI.bash), strdup(script.path)]
    for i in 1..<Int(CommandLine.argc) {
        argv.append(CommandLine.unsafeArgv[i].map { strdup($0) } ?? nil)
    }
    argv.append(nil)
    execv(LegacyCLI.bash, argv)
    fail("qs: can't run \(LegacyCLI.bash) \(script.path): \(String(cString: strerror(errno)))", status: 126)
}

setlocale(LC_ALL, "")
let env = ProcessInfo.processInfo.environment

// The same refusals qs.bash makes before it looks at any argument.
if geteuid() == 0 { abort("this script should not be run as root") }
if !(env["QS_SESSION_ID"] ?? "").isEmpty { abort("already inside a quicksand sandbox") }

switch QsCLI.parse(Array(CommandLine.arguments.dropFirst()),
                   defaults: QsCLI.splitDefaults(env["QUICKSAND_ARGS"] ?? ""),
                   verbose: Int(env["QS_VERBOSE"] ?? "") ?? 0) {
case .help:
    print(QsCLI.helpText)
case .version:
    print("qs version \(QsCLI.version)")
case .failure(let message):
    abort(message)
case .run(let args) where args.command == .list:
    // The QS_LIST_* overrides exist only so tests can use a fixture tree.
    let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
    print(SandboxList.render(homes: URL(fileURLWithPath: env["QS_LIST_HOMES_DIR"] ?? "/Users"),
                             shared: URL(fileURLWithPath: env["QS_LIST_SHARED_DIR"] ?? "/Users/Shared"),
                             installDir: home.appendingPathComponent(".config/quicksand")),
          terminator: "")
case .run:
    runBash()
}
