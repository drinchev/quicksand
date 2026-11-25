import Darwin
import Foundation

/// One line of `events.jsonl`, as the brokers write it (see
/// docs/quicksand-app.md). Every string a sandbox sent arrives escaped but
/// is still untrusted: show it, never act on it.
public struct BrokerEvent: Codable, Hashable, Sendable, Identifiable {
    public var ts: String
    public var sandbox: String
    public var broker: String
    public var verb: String
    public var result: String
    public var secs: Int?
    public var exit: Int?
    public var target: String?
    public var reason: String?
    public var providers: String?

    /// Position in the log since the app started; stable row identity.
    public var seq: Int = 0
    public var date: Date?

    public var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case ts, sandbox, broker, verb, result, secs, exit, target, reason, providers
    }

    public var kind: BrokerKind? { BrokerKind(rawValue: broker) }
    /// Rejected by policy, or failed on the host.
    public var isProblem: Bool { result == "error" || result == "rejected" }

    /// One line of text for lists: what was asked, and why it went wrong.
    public var summary: String {
        var parts = [verb]
        if let target, !target.isEmpty { parts.append(target) }
        if let providers, !providers.isEmpty { parts.append(providers) }
        return parts.joined(separator: " ")
    }

    public static func decode(line: Data) -> BrokerEvent? {
        guard var event = try? JSONDecoder().decode(BrokerEvent.self, from: line) else { return nil }
        event.date = try? Date(event.ts, strategy: .iso8601)
        return event
    }
}

/// Follows `events.jsonl` as the brokers append to it, across rotation
/// (the brokers move it to `events.jsonl.1` past its size cap).
public final class EventLogReader {
    public let url: URL
    public let keep: Int
    public private(set) var events: [BrokerEvent] = []

    private var offset: UInt64 = 0
    private var inode: ino_t = 0
    private var partial = Data()
    private var nextSeq = 1

    public init(url: URL, keep: Int = 5000) {
        self.url = url
        self.keep = keep
    }

    /// Read whatever was appended since the last call. Returns true if new
    /// events arrived. Lines that aren't valid events are skipped.
    @discardableResult
    public func poll() -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        let size = UInt64(st.st_size)
        if st.st_ino != inode || size < offset {
            // New or rotated file: start from its beginning.
            inode = st.st_ino
            offset = 0
            partial = Data()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return false }
        offset += UInt64(data.count)
        partial.append(data)

        var added = false
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial = Data(partial[partial.index(after: newline)...])
            guard !line.isEmpty, var event = BrokerEvent.decode(line: Data(line)) else { continue }
            event.seq = nextSeq
            nextSeq += 1
            events.append(event)
            added = true
        }
        if events.count > keep { events.removeFirst(events.count - keep) }
        return added
    }
}

/// Counts over a time window, for the status bar.
public struct EventStats: Equatable, Sendable {
    public var total = 0
    public var problems = 0
    public var byBroker: [String: Int] = [:]
    /// Newest event per sandbox (over all events, not just the window).
    public var lastBySandbox: [String: BrokerEvent] = [:]

    public init() {}

    public static func summarize(_ events: [BrokerEvent], since: Date) -> EventStats {
        var stats = EventStats()
        for event in events {
            stats.lastBySandbox[event.sandbox] = event
            guard let date = event.date, date >= since else { continue }
            stats.total += 1
            if event.isProblem { stats.problems += 1 }
            stats.byBroker[event.broker, default: 0] += 1
        }
        return stats
    }
}
