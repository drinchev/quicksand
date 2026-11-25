import Darwin
import Foundation

/// Speech for sandboxes (the `qs-say` client), inside the app. macOS
/// text-to-speech only works in a GUI session, which the sandbox users never
/// have and the app always runs in (see config/qs-say).
///
/// The client is untrusted: it sends one line of text and nothing it sends
/// becomes an argument. Control characters are dropped, the length is
/// capped, and what remains goes to `say` on stdin. The worst a hostile
/// sandbox can do is make the Mac say something.
public final class SayBroker: InProcessBroker, @unchecked Sendable {
    public static let maxRequestBytes = 4096
    public static let maxMessageBytes = 300
    public static let readTimeout: TimeInterval = 10
    /// How long a message waits for the one before it before speaking anyway
    /// (a stuck `say` must not silence everyone for good).
    public static let queueWait: TimeInterval = 20
    /// A `say` that runs longer than this is stopped.
    public static let sayTimeout: TimeInterval = 60

    private let paths: QuicksandPaths
    private let sayCommand: String
    private let ownerUID: uid_t
    /// One message at a time across every sandbox, so they queue instead of
    /// talking over each other.
    private let speaking = DispatchSemaphore(value: 1)

    public init(paths: QuicksandPaths, sayCommand: String = "/usr/bin/say", ownerUID: uid_t = getuid()) {
        self.paths = paths
        self.sayCommand = sayCommand
        self.ownerUID = ownerUID
    }

    /// Every built sandbox may speak; `qs build` writes the install marker.
    public func refusal(for sandbox: String) -> String? {
        let marker = paths.installMarker(sandbox).path
        return checkOwnedFile(marker, ownerUID: ownerUID) == .ok ? nil
            : "this sandbox isn't built — on the host, run: qs build \(sandbox)"
    }

    public func serve(_ client: BrokerClient, sandbox: String) -> Int32 {
        let started = Date()
        // Read the line, then hang up at once: the client's wait ends before
        // any speech starts.
        let request = client.readLine(maxBytes: Self.maxRequestBytes, timeout: Self.readTimeout)
        client.close()

        let message = Self.message(from: request)
        guard !message.isEmpty else { return 0 }

        let queued = speaking.wait(timeout: .now() + Self.queueWait) == .success
        defer { if queued { speaking.signal() } }
        let spoke = say(message)

        let line = try? EventWriter.line(
            broker: BrokerKind.say.rawValue, sandbox: Data(sandbox.utf8), verb: Data("say".utf8),
            result: spoke ? "ok" : "error",
            fields: [("target", message)] + (spoke ? [] : [("reason", Data("say failed".utf8))]),
            started: started)
        if let line { try? EventWriter.append(line, to: paths.eventsLog) }
        return spoke ? 0 : 1 << 8
    }

    /// What gets spoken: the request without control bytes, cut to
    /// `maxMessageBytes` without splitting a UTF-8 character. Empty when
    /// nothing but spaces is left.
    public static func message(from request: Data) -> Data {
        var kept = Data(request.filter { $0 >= 0x20 && $0 != 0x7f }.prefix(maxMessageBytes))
        // Drop a character the cut split in two (at most 3 trailing bytes).
        for _ in 0..<3 where String(data: kept, encoding: .utf8) == nil && !kept.isEmpty {
            kept.removeLast()
        }
        return kept.allSatisfy({ $0 == 0x20 }) ? Data() : kept
    }

    /// Run `say` with `message` on stdin. True when it exited 0 in time.
    func say(_ message: Data) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sayCommand)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return false }
        // A `say` that exits without reading must cost an EPIPE, not a
        // SIGPIPE that takes the whole app down.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForWriting.write(contentsOf: message + Data("\n".utf8))
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + Self.sayTimeout) == .timedOut {
            process.terminate()
            exited.wait()
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
