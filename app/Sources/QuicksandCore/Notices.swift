import Foundation

/// Which broker connections the app announces with a notification.
public enum NoticeMode: String, CaseIterable, Sendable {
    /// Every connection to a broker, plus refusals and failures.
    case all
    /// Only refusals and requests that failed.
    case problems
    case off
}

/// The notification for one update of a broker connection. The app never
/// reads requests, so it can say who called which broker and how that
/// ended, not what was asked.
public struct BrokerNotice: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Groups notifications per sandbox in Notification Center.
    public let thread: String

    /// `isNew` is true for the first update of a connection. Returns nil when
    /// this update isn't worth a notification under `mode`.
    public static func make(for conn: BrokerConnection, isNew: Bool, mode: NoticeMode) -> BrokerNotice? {
        let broker = conn.kind.displayName
        let who = conn.sandbox ?? conn.uid.map { "uid \($0)" } ?? "an unknown process"
        let thread = conn.sandbox ?? "not-a-sandbox"

        switch (conn.outcome, mode) {
        case (_, .off):
            return nil
        case (.running, .all) where isNew:
            return BrokerNotice(title: "\(who) → \(broker)",
                                body: "\(who) is using the \(broker.lowercased()) broker.",
                                thread: thread)
        case (.running, _):
            return nil
        case (.rejected(let why), _):
            let caller = conn.sandbox == nil ? "\(who) (not a sandbox)" : who
            return BrokerNotice(title: "Refused \(caller) → \(broker)", body: why, thread: thread)
        case (.finished(_, let status), _):
            let code = exitCode(status)
            guard code != 0 else { return nil }
            return BrokerNotice(title: "\(who) → \(broker) failed",
                                body: code.map { "The broker exited with status \($0)." }
                                    ?? "The broker was killed by a signal.",
                                thread: thread)
        }
    }

    /// The exit code in a raw wait status, or nil when a signal ended it.
    static func exitCode(_ status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}

extension BrokerKind {
    public var displayName: String {
        switch self {
        case .docker: return "Docker"
        case .auth: return "Credentials"
        case .say: return "Speech"
        }
    }
}
