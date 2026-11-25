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
    /// `~/Library/LaunchAgents`, where builds before the app put each
    /// sandbox's brokers. Only looked at to spot leftovers.
    public var launchAgentsDir: URL?
    /// Where the app creates the shared broker sockets
    /// (`/Users/Shared/quicksand`).
    public var socketDir: URL

    public init(usersDir: URL, sharedDir: URL, installDir: URL,
                launchAgentsDir: URL? = nil, socketDir: URL) {
        self.usersDir = usersDir
        self.sharedDir = sharedDir
        self.installDir = installDir
        self.launchAgentsDir = launchAgentsDir
        self.socketDir = socketDir
    }

    /// The real locations for the current user.
    public static func host(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> QuicksandPaths {
        let installDir = home.appendingPathComponent(".config/quicksand")
        return QuicksandPaths(
            usersDir: URL(fileURLWithPath: "/Users"),
            sharedDir: URL(fileURLWithPath: "/Users/Shared"),
            installDir: installDir,
            launchAgentsDir: home.appendingPathComponent("Library/LaunchAgents"),
            socketDir: URL(fileURLWithPath: "/Users/Shared/quicksand")
        )
    }

    /// One JSON line per broker request (written by the brokers).
    public var eventsLog: URL { installDir.appendingPathComponent("events.jsonl") }

    /// Written by every `qs build NAME`: the sandbox is set up.
    public func installMarker(_ sandbox: String) -> URL {
        installDir.appendingPathComponent("install-\(sandbox)")
    }

    /// Created by `qs docker NAME`, removed by `qs docker NAME off`: the
    /// sandbox may use Docker.
    public func dockerMarker(_ sandbox: String) -> URL {
        installDir.appendingPathComponent("docker-\(sandbox)")
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

    /// What builds before the brokers moved into the app set up for this
    /// sandbox: a spec and a staged bash broker per broker, or (before the
    /// app) a LaunchAgent. The next build removes them; until then Docker
    /// from an old spec isn't served.
    public func oldBrokerFiles(_ sandbox: String) -> [URL] {
        BrokerKind.allCases.flatMap { kind -> [URL] in
            let plist = "\(kind.label(for: sandbox)).plist"
            return [installDir.appendingPathComponent("brokers/\(plist)"),
                    installDir.appendingPathComponent("\(kind.rawValue)-broker-\(sandbox).sh")]
                + (launchAgentsDir.map { [$0.appendingPathComponent(plist)] } ?? [])
        }
    }
}
