import Foundation

/// The three host-side brokers. Each has one shared socket; which sandbox is
/// calling comes from the connection, never from the socket or the request.
public enum BrokerKind: String, CaseIterable, Sendable, Codable, Hashable {
    case docker, auth, say

    public var socketName: String { "\(rawValue).sock" }

    /// The LaunchAgent label qs renders for this broker and sandbox.
    public func label(for sandbox: String) -> String {
        "com.quicksand.\(rawValue)-broker.\(sandbox)"
    }

    /// What a turned-away caller is told, in this broker's own protocol, so
    /// the sandbox-side client prints it and fails the way it already does:
    /// `qs-docker` relays text and exits with the sentinel's code;
    /// `qs-auth-refresh` treats a reply without `done` as a failed refresh;
    /// `qs-say` expects no reply at all.
    public func rejection(_ message: String) -> Data {
        switch self {
        case .docker: return Data("qs-docker: \(message)\n\n@@qs-docker-exit:125@@\n".utf8)
        case .auth: return Data("qs-auth-broker: \(message)\n".utf8)
        case .say: return Data()
        }
    }
}
