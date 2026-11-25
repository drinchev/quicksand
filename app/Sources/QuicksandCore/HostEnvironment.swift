import Darwin
import Foundation

/// What the app needs to know about the host's tools, worked out by the app
/// itself instead of being pinned into every sandbox's spec at build time.
public enum HostEnvironment {
    /// Used when the login shell can't be asked: the usual places on macOS.
    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The PATH your shell has in a terminal — where `op`, `gcloud` and
    /// `docker` are found. An app started from Finder or at login gets a bare
    /// PATH, so ask the login shell once. Interactive too (zsh reads .zshrc
    /// only then, and installers like gcloud's add to PATH there); if that
    /// fails or hangs, a plain login shell; then `fallbackPath`.
    public static func loginShellPath(shell: String = userShell(), timeout: TimeInterval = 5) -> String {
        for flags in [["-l", "-i"], ["-l"]] {
            if let path = askShell(shell, flags: flags, timeout: timeout) { return path }
        }
        return fallbackPath
    }

    /// The cached `loginShellPath()`, worked out on first use.
    public static let cachedLoginShellPath: String = loginShellPath()

    /// The host user's login shell (zsh when unknown).
    public static func userShell() -> String {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.hasPrefix("/") ? path : "/bin/zsh"
    }

    /// Run `shell FLAGS -c` printing PATH between markers (a .zshrc may
    /// print its own output), with no terminal and a deadline.
    static func askShell(_ shell: String, flags: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = flags + ["-c", #"printf '\n@@QS_PATH@@%s@@\n' "$PATH""#]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "quicksand.loginshell")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + 1)
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "@@QS_PATH@@"),
              let end = text.range(of: "@@", range: start.upperBound..<text.endIndex) else { return nil }
        let path = String(text[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// The bash `qs` scripts' directory the app ships (Contents/Resources/
    /// quicksand), or a checkout above a `swift build` binary: where
    /// `libexec/` and `config/` are.
    public static func quicksandDir(executable: URL? = LegacyCLI.currentExecutable()) -> URL? {
        LegacyCLI.locateScript(environment: [:], executable: executable)?.deletingLastPathComponent()
    }
}
