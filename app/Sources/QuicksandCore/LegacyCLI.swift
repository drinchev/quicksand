import Darwin
import Foundation

/// The bash `qs` (`qs.bash`) that the Swift `qs` hands every command to while
/// commands move into Swift one at a time.
public enum LegacyCLI {
    public static let scriptName = "qs.bash"
    /// Where `bundle.sh` puts `qs.bash` and the directories it reads
    /// (profile.d/, logout.d/, config/, libexec/), relative to Contents/.
    public static let bundledDir = "Resources/quicksand"
    /// The interpreter `qs.bash` is written for (its shebang).
    public static let bash = "/bin/bash"

    /// Find `qs.bash`, in order:
    /// 1. `QS_BASH`, when set (tests, development);
    /// 2. inside the app: `Contents/Resources/quicksand/qs.bash`, next to
    ///    `Contents/MacOS/qs`;
    /// 3. a checkout: the nearest directory above the executable that holds
    ///    `qs.bash` and `profile.d/` (for `app/.build/debug/qs`).
    ///
    /// `executable` must already have its symlinks resolved, so a
    /// `/usr/local/bin/qs` link finds the app it points into.
    public static func locateScript(environment: [String: String], executable: URL?,
                                    isFile: (String) -> Bool = isRegularFile,
                                    isDirectory: (String) -> Bool = isDirectory) -> URL? {
        if let override = environment["QS_BASH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let executable else { return nil }
        let binDir = executable.deletingLastPathComponent()

        let bundled = binDir.deletingLastPathComponent()
            .appendingPathComponent(bundledDir).appendingPathComponent(scriptName)
        if isFile(bundled.path) { return bundled.standardizedFileURL }

        var dir = binDir
        while dir.path != "/" {
            let script = dir.appendingPathComponent(scriptName)
            if isFile(script.path) && isDirectory(dir.appendingPathComponent("profile.d").path) {
                return script.standardizedFileURL
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The argv to exec: bash, the script, then the user's arguments as given.
    public static func arguments(script: URL, passing args: [String]) -> [String] {
        [bash, script.path] + args
    }

    /// This process's executable with symlinks resolved, or nil.
    public static func currentExecutable() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        guard let resolved = realpath(buf, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    public static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
