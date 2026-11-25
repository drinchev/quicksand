import Foundation

/// Where quicksand keeps things on the host. Every path is injectable so the
/// tests can point the app at a fixture tree.
public struct QuicksandPaths: Sendable {
    /// Sandbox homes live here as `qs-NAME` (`/Users`).
    public var usersDir: URL
    /// Shared workspaces live here as `qs-NAME` (`/Users/Shared`).
    public var sharedDir: URL
    /// The host-side config directory qs writes (`~/.config/quicksand`).
    public var installDir: URL
    /// Where qs renders each sandbox's broker specs
    /// (`~/.config/quicksand/brokers`).
    public var specDir: URL
    /// Where builds before the app put them, as LaunchAgents
    /// (`~/Library/LaunchAgents`). Read until the sandbox is rebuilt.
    public var legacySpecDir: URL?
    /// Where the app creates the shared broker sockets
    /// (`/Users/Shared/quicksand`).
    public var socketDir: URL

    public init(usersDir: URL, sharedDir: URL, installDir: URL, specDir: URL,
                legacySpecDir: URL? = nil, socketDir: URL) {
        self.usersDir = usersDir
        self.sharedDir = sharedDir
        self.installDir = installDir
        self.specDir = specDir
        self.legacySpecDir = legacySpecDir
        self.socketDir = socketDir
    }

    /// The real layout on this Mac, for the user running the app.
    public static func host(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> QuicksandPaths {
        let installDir = home.appendingPathComponent(".config/quicksand")
        return QuicksandPaths(
            usersDir: URL(fileURLWithPath: "/Users"),
            sharedDir: URL(fileURLWithPath: "/Users/Shared"),
            installDir: installDir,
            specDir: installDir.appendingPathComponent("brokers"),
            legacySpecDir: home.appendingPathComponent("Library/LaunchAgents"),
            socketDir: URL(fileURLWithPath: "/Users/Shared/quicksand")
        )
    }

    /// One JSON line per broker request (written by the brokers).
    public var eventsLog: URL { installDir.appendingPathComponent("events.jsonl") }

    /// Written by every `qs build NAME`: the sandbox is set up.
    public func installMarker(_ sandbox: String) -> URL {
        installDir.appendingPathComponent("install-\(sandbox)")
    }

    public func workspace(_ sandbox: String) -> URL {
        sharedDir.appendingPathComponent("qs-\(sandbox)")
    }

    /// The workspace's private area (staged tokens, session records).
    public func privateDir(_ sandbox: String) -> URL {
        workspace(sandbox).appendingPathComponent("_quicksand")
    }

    public func socket(_ kind: BrokerKind) -> URL {
        socketDir.appendingPathComponent(kind.socketName)
    }

    /// The spec to use: qs's current one, else a LaunchAgent plist from a
    /// build before the app (same keys; the app ignores launchd's socket).
    public func spec(_ kind: BrokerKind, sandbox: String) -> URL {
        let current = specDir.appendingPathComponent(specName(kind, sandbox))
        if let legacy = legacySpec(kind, sandbox: sandbox),
           !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return current
    }

    /// True when the sandbox's broker still runs from a LaunchAgent, i.e. it
    /// wasn't rebuilt since the app took over (`qs build NAME` moves it).
    public func usesLaunchAgent(_ kind: BrokerKind, sandbox: String) -> Bool {
        guard let legacy = legacySpec(kind, sandbox: sandbox) else { return false }
        return spec(kind, sandbox: sandbox) == legacy
    }

    private func specName(_ kind: BrokerKind, _ sandbox: String) -> String {
        "\(kind.label(for: sandbox)).plist"
    }

    private func legacySpec(_ kind: BrokerKind, sandbox: String) -> URL? {
        legacySpecDir?.appendingPathComponent(specName(kind, sandbox))
    }
}
