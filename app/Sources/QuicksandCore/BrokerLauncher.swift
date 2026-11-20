import Darwin
import Foundation

/// Starts a bash broker with a client connection as its stdin and stdout —
/// what launchd's inetd mode does today.
public enum BrokerLauncher {
    /// The environment launchd gives a LaunchAgent, which the brokers were
    /// written against. A spec's own variables are layered on top.
    public static func baseEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var base: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = env[key] { base[key] = value }
        }
        return base
    }

    public struct SpawnError: Error, Equatable {
        public let code: Int32
    }

    /// Spawn `spec` with `fd` as fd 0 and 1 and /dev/null as fd 2 (each
    /// broker sends its own stderr to its host-side log). Every other
    /// descriptor of the app is closed in the child, and signal handling is
    /// reset, so the broker starts as clean as a launchd one.
    public static func spawn(_ spec: BrokerSpec, connection fd: Int32,
                             baseEnvironment: [String: String] = baseEnvironment()) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fd, 0)
        posix_spawn_file_actions_adddup2(&actions, fd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        let env = baseEnvironment.merging(spec.environment) { _, specValue in specValue }
        let envList = env.map { "\($0.key)=\($0.value)" }.sorted()

        var pid: pid_t = 0
        let rc = withCStringArray(spec.arguments) { argv in
            withCStringArray(envList) { envp in
                posix_spawn(&pid, spec.arguments[0], &actions, &attr, argv, envp)
            }
        }
        guard rc == 0 else { throw SpawnError(code: rc) }
        return pid
    }

    /// Block until `pid` exits; returns its wait status. Called on a thread
    /// of its own per child (see BrokerListener).
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
