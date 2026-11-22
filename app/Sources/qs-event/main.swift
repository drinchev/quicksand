// qs-event — append one request to the broker event log.
//
//   qs-event --log FILE --broker docker|auth|say --sandbox NAME [--since EPOCH] \
//            -- VERB RESULT [FIELD VALUE]...
//
// The bash brokers (config/qs-*-broker) call it once per finished request;
// Quicksand.app ships it next to its own binary and passes its path to every
// broker as QS_EVENT_BIN. FIELD names come from the broker script; VERB and
// the values may come from a sandbox and are cleaned (see EventWriter).
// QS_EVENTS_MAX_BYTES overrides the rotation size (default 5 MB).
//
// Exit status: 0 when the line was written, 1 when it couldn't be, 2 for a
// usage error. Brokers ignore it: logging must never break a request.
import Darwin
import Foundation
import QuicksandCore

func fail(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data("qs-event: \(message)\n".utf8))
    exit(status)
}

// Raw bytes, not CommandLine.arguments: that would turn invalid UTF-8 into
// U+FFFD, and EventWriter drops invalid bytes instead.
let args: [Data] = (1..<Int(CommandLine.argc)).map { i in
    let p = CommandLine.unsafeArgv[i]!
    return Data(bytes: p, count: strlen(p))
}
func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

var log: String?, broker: String?, sandbox: Data?, since: Date?
var i = 0
options: while i < args.count {
    let flag = text(args[i])
    func value() -> Data {
        guard i + 1 < args.count else { fail("\(flag) needs a value", 2) }
        i += 1
        return args[i]
    }
    switch flag {
    case "--log": log = text(value())
    case "--broker": broker = text(value())
    case "--sandbox": sandbox = value()
    case "--since":
        guard let t = TimeInterval(text(value())) else { fail("--since needs seconds since the epoch", 2) }
        since = Date(timeIntervalSince1970: t)
    case "--": i += 1; break options
    case "-h", "--help":
        print("usage: qs-event --log FILE --broker docker|auth|say --sandbox NAME [--since EPOCH] -- VERB RESULT [FIELD VALUE]...")
        exit(0)
    default: fail("unknown option '\(flag)' (try --help)", 2)
    }
    i += 1
}
guard let log, let broker, let sandbox else { fail("--log, --broker and --sandbox are required", 2) }
let rest = Array(args[i...])
guard rest.count >= 2 else { fail("VERB and RESULT are required", 2) }
guard rest.count % 2 == 0 else { fail(EventWriter.UsageError.oddFields.description, 2) }
let fields = stride(from: 2, to: rest.count, by: 2).map { (text(rest[$0]), rest[$0 + 1]) }

do {
    let line = try EventWriter.line(broker: broker, sandbox: sandbox, verb: rest[0], result: text(rest[1]),
                                    fields: fields, started: since)
    let max = ProcessInfo.processInfo.environment["QS_EVENTS_MAX_BYTES"].flatMap(Int.init) ?? EventWriter.defaultMaxBytes
    try EventWriter.append(line, to: URL(fileURLWithPath: log), maxBytes: max)
} catch let error as EventWriter.UsageError {
    fail(error.description, 2)
} catch {
    fail("couldn't write \(log): \(error)", 1)
}
