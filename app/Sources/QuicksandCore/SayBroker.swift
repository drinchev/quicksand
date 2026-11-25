import Darwin
import Foundation

/// Speech for sandboxes (the `qs-say` client), inside the app. macOS
/// text-to-speech only works in a GUI session, which the sandbox users never
/// have and the app always runs in (see config/qs-say).
///
/// The client is untrusted: it sends one line of text. Control characters
/// are dropped, the length is capped, and what remains is spoken by the
/// app's `Speaker` (macOS's speech synthesizer) as plain text. The worst a
/// hostile sandbox can do is make the Mac say something.
public final class SayBroker: InProcessBroker, @unchecked Sendable {
    public static let maxRequestBytes = 4096
    public static let maxMessageBytes = 300
    public static let readTimeout: TimeInterval = 10
    /// How long a request waits for its message to be spoken, including the
    /// messages queued before it.
    public static let speakTimeout: TimeInterval = 90

    private let paths: QuicksandPaths
    private let speaker: Speaker
    private let ownerUID: uid_t

    public init(paths: QuicksandPaths, speaker: Speaker = SystemSpeaker.shared, ownerUID: uid_t = getuid()) {
        self.paths = paths
        self.speaker = speaker
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

        let spoke = speaker.speak(String(decoding: message, as: UTF8.self), timeout: Self.speakTimeout)

        let line = try? EventWriter.line(
            broker: BrokerKind.say.rawValue, sandbox: Data(sandbox.utf8), verb: Data("say".utf8),
            result: spoke ? "ok" : "error",
            fields: [("target", message)] + (spoke ? [] : [("reason", Data("not spoken".utf8))]),
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
}
