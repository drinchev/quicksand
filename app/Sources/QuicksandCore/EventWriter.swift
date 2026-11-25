import Darwin
import Foundation

/// Writes one line of the broker event log (`events.jsonl`): each in-app
/// broker records every request it finished. `EventLogReader` reads it back
/// for the menu and the Activity window.
///
/// Values a sandbox sent are untrusted: invalid UTF-8 and control
/// characters are dropped and everything is JSON-escaped, so each line is
/// valid JSON whatever the client sent.
public enum EventWriter {
    public static let defaultMaxBytes = 5_000_000
    static let reservedFields: Set<String> = ["ts", "sandbox", "broker", "verb", "result", "secs"]

    public enum UsageError: Error, Equatable, CustomStringConvertible {
        case badBroker(String)
        case badResult(String)
        case badField(String)
        case oddFields

        public var description: String {
            switch self {
            case .badBroker(let b): return "unknown broker '\(b)' (docker, auth or say)"
            case .badResult(let r): return "result must be a lowercase word, got '\(r)'"
            case .badField(let f): return "field name must be a lowercase word other than ts/sandbox/broker/verb/result/secs, got '\(f)'"
            case .oddFields: return "fields come in FIELD VALUE pairs"
            }
        }
    }

    /// The JSON line (without the newline). `fields` are FIELD VALUE pairs:
    /// field names come from the broker script, values may come from the
    /// client. Empty values are left out; `exit` is written as a number (and
    /// left out unless it is one).
    public static func line(broker: String, sandbox: Data, verb: Data, result: String,
                            fields: [(String, Data)], started: Date?, now: Date = Date()) throws -> String {
        guard BrokerKind(rawValue: broker) != nil else { throw UsageError.badBroker(broker) }
        guard isWord(result) else { throw UsageError.badResult(result) }

        var out = "{\"ts\":\(quote(timestamp(now)))"
        out += ",\"sandbox\":\(quote(clean(sandbox)))"
        out += ",\"broker\":\(quote(broker))"
        out += ",\"verb\":\(quote(clean(verb)))"
        out += ",\"result\":\(quote(result))"
        if let started {
            out += ",\"secs\":\(max(0, Int(now.timeIntervalSince(started))))"
        }
        for (name, raw) in fields {
            guard isWord(name), !reservedFields.contains(name) else { throw UsageError.badField(name) }
            let value = clean(raw)
            if name == "exit" {
                if !value.isEmpty, value.count <= 9, value.allSatisfy(\.isASCIIDigit) {
                    out += ",\"exit\":\(Int(value)!)"
                }
            } else if !value.isEmpty {
                out += ",\(quote(name)):\(quote(value))"
            }
        }
        return out + "}"
    }

    /// Append `line` to `log`, moving the log to `log.1` first once it has
    /// reached `maxBytes`. Holds an exclusive lock on the log while doing
    /// so, so concurrent brokers neither interleave nor rotate twice.
    public static func append(_ line: String, to log: URL, maxBytes: Int = defaultMaxBytes) throws {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        for _ in 0..<5 {
            let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            flock(fd, LOCK_EX)
            // Another writer may have rotated the file while we waited for
            // the lock: then this fd is log.1, so start over on the new one.
            var mine = stat(), current = stat()
            guard fstat(fd, &mine) == 0, stat(log.path, &current) == 0,
                  mine.st_ino == current.st_ino, mine.st_dev == current.st_dev else { continue }
            if mine.st_size >= maxBytes {
                rename(log.path, log.path + ".1")
                continue
            }
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
    }

    // MARK: - Helpers

    /// Drop invalid UTF-8 and control characters (C0, DEL, C1).
    static func clean(_ raw: Data) -> String {
        var kept = String.UnicodeScalarView()
        var decoder = UTF8()
        var bytes = raw.makeIterator()
        loop: while true {
            switch decoder.decode(&bytes) {
            case .scalarValue(let s):
                if s.value >= 0x20 && !(0x7f...0x9f).contains(s.value) { kept.append(s) }
            case .error: continue
            case .emptyInput: break loop
            }
        }
        return String(kept)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func isWord(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
