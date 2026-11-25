import Darwin
import Foundation

/// What the host can tell about one sandbox without entering it.
public struct SandboxStatus: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let uid: uid_t?
    /// Programs running as the sandbox user — shells, agents, builds — not
    /// counting what lingers after a session ends (see
    /// `ProcessTable.isActivity`). Empty means idle.
    public let processes: [String]
    public var processCount: Int { processes.count }
    /// Live session records in `_quicksand/sessions/`.
    public let sessionCount: Int
    /// `qs docker NAME` turned Docker on for this sandbox.
    public let dockerEnabled: Bool
    /// Age of the staged GCP access token (they last about an hour).
    public let gcpTokenAge: TimeInterval?
    public let opTokenStaged: Bool
    /// Files from before the brokers moved into the app (specs, staged bash
    /// brokers, LaunchAgents). Docker set up that way isn't served until a
    /// rebuild (`qs build NAME`) moves it to the marker.
    public let oldBrokerFiles: [String]

    /// Rebuilding would bring this sandbox's broker setup up to date.
    public var needsRebuild: Bool { !oldBrokerFiles.isEmpty }

    public var isActive: Bool { !processes.isEmpty || sessionCount > 0 }
}

public struct SandboxScanner: Sendable {
    public let paths: QuicksandPaths
    public let users: UserDirectory
    private let listProcesses: @Sendable (uid_t) -> [String]

    /// `listProcesses` returns the executable paths of a uid's processes.
    public init(paths: QuicksandPaths, users: UserDirectory = SystemUserDirectory(),
                listProcesses: @escaping @Sendable (uid_t) -> [String] = ProcessTable.executables(uid:)) {
        self.paths = paths
        self.users = users
        self.listProcesses = listProcesses
    }

    /// Sandboxes are the `qs-NAME` homes under `usersDir`, as `qs list` sees them.
    public func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: paths.usersDir.path)) ?? []
        return entries.compactMap { SandboxName.from(username: $0) }.sorted()
    }

    public func scan(now: Date = Date()) -> [SandboxStatus] {
        names().map { status(of: $0, now: now) }
    }

    public func status(of name: String, now: Date = Date()) -> SandboxStatus {
        let uid = users.uid(forUsername: "qs-\(name)")
        let priv = paths.privateDir(name)
        let fm = FileManager.default

        let gcpAge = (try? fm.attributesOfItem(atPath: priv.appendingPathComponent("gcp-token").path))
            .flatMap { $0[.modificationDate] as? Date }
            .map { now.timeIntervalSince($0) }

        let programs = (uid.map(listProcesses) ?? [])
            .filter(ProcessTable.isActivity)
            .map { URL(fileURLWithPath: $0).lastPathComponent }

        return SandboxStatus(
            name: name,
            uid: uid,
            processes: programs.sorted(),
            sessionCount: liveSessions(in: priv.appendingPathComponent("sessions")),
            dockerEnabled: fm.fileExists(atPath: paths.dockerMarker(name).path),
            gcpTokenAge: gcpAge,
            opTokenStaged: fm.fileExists(atPath: priv.appendingPathComponent("op-token").path),
            oldBrokerFiles: paths.oldBrokerFiles(name).map(\.path).filter { fm.fileExists(atPath: $0) }
        )
    }

    /// Session records are empty files named after a PID; a session that died
    /// without its logout hooks leaves one behind, so check the PID is alive.
    func liveSessions(in dir: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.compactMap { pid_t($0) }.filter { $0 > 0 && isAlive($0) }.count
    }
}

/// kill(pid, 0): EPERM still means the process exists (it belongs to the
/// sandbox user, not us).
func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

public enum ProcessTable {
    /// Executable paths of the processes running as `uid`. macOS shows every
    /// user's processes, so this needs no privilege. Processes whose path
    /// can't be read (already exited) are skipped.
    @Sendable public static func executables(uid: uid_t) -> [String] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let bytes = pids.withUnsafeMutableBytes { buf in
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buf.baseAddress, Int32(buf.count))
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.compactMap { pid in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return String(cString: path)
        }
    }

    /// macOS starts per-user daemons for any account that has logged in and
    /// leaves them running (cfprefsd, distnoted, lsd, trustd, …). They live in
    /// the system's own directories; nothing a sandbox runs does.
    public static func isSystemDaemon(_ path: String) -> Bool {
        ["/usr/sbin/", "/usr/libexec/", "/sbin/", "/System/"].contains { path.hasPrefix($0) }
    }

    /// Background helpers that outlive the session that started them: the
    /// 1Password CLI's `op` daemon, and the Claude desktop app's SSH-side
    /// server (`~/.claude/remote/srv/…/server`), which stays up after the app
    /// disconnects. While someone is really there, a shell, an agent or an
    /// sshd session runs alongside them.
    public static func isLingeringHelper(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "op" || path.contains("/.claude/remote/srv/")
    }

    /// Does this process mean someone is using the sandbox?
    @Sendable public static func isActivity(_ path: String) -> Bool {
        !isSystemDaemon(path) && !isLingeringHelper(path)
    }
}
