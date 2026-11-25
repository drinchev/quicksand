// qs — the quicksand command. For now it only finds the bash qs (qs.bash)
// and replaces itself with `/bin/bash qs.bash ARGS...`: exec, not a child
// process, so the terminal, sudo prompts, Ctrl-C, interactive sessions and
// the exit code are exactly the bash script's. Commands move into Swift
// one at a time; see docs/quicksand-app.md.
import Darwin
import Foundation
import QuicksandCore

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("qs: \(message)\n".utf8))
    exit(status)
}

guard let script = LegacyCLI.locateScript(environment: ProcessInfo.processInfo.environment,
                                          executable: LegacyCLI.currentExecutable()) else {
    fail("can't find \(LegacyCLI.scriptName) — reinstall Quicksand.app, or set QS_BASH to its path",
         status: 127)
}

// The user's arguments go through as the raw bytes we were given (not via
// CommandLine.arguments, which would repair invalid UTF-8).
var argv: [UnsafeMutablePointer<CChar>?] = [strdup(LegacyCLI.bash), strdup(script.path)]
for i in 1..<Int(CommandLine.argc) {
    argv.append(CommandLine.unsafeArgv[i].map { strdup($0) } ?? nil)
}
argv.append(nil)

execv(LegacyCLI.bash, argv)
fail("can't run \(LegacyCLI.bash) \(script.path): \(String(cString: strerror(errno)))", status: 126)
