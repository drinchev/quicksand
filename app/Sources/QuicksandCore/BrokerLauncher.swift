import Darwin
import Foundation

/// Starts the programs the in-app brokers run (`docker`, the auth
/// providers) cleanly: only the descriptors a caller sets up, default
/// signal handling, and an environment of its own.
public enum BrokerLauncher {
    /// What a child gets from the app's environment: a bare PATH (callers
    /// put the login shell's in), the shell, and who and where you are.
    public static func environment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var base: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = env[key] { base[key] = value }
        }
        return base
    }

    /// posix_spawn `path` with `argv` and `env`, applying `actions` (which
    /// set up its descriptors). Every other descriptor of the app is closed
    /// in the child (POSIX_SPAWN_CLOEXEC_DEFAULT) and signal handling is
    /// reset. `ownGroup` puts it in a new process group, so the whole group
    /// can be stopped. Returns the pid, or nil when it couldn't start.
    public static func spawn(_ path: String, _ argv: [String], env: [String: String],
                             actions: inout posix_spawn_file_actions_t?, ownGroup: Bool = false) -> pid_t? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if ownGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attr, 0)
        }
        posix_spawnattr_setflags(&attr, Int16(flags))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        let envList = env.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let rc = withCStringArray(argv) { cargv in
            withCStringArray(envList) { cenv in posix_spawn(&pid, path, &actions, &attr, cargv, cenv) }
        }
        return rc == 0 ? pid : nil
    }

    /// Block until `pid` exits; returns its wait status.
    public static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }
}

func withCStringArray<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
