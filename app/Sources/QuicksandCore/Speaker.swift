import Darwin
import Foundation

/// Something that speaks text aloud on the host.
public protocol Speaker: Sendable {
    /// Speak `text` and return once it was spoken (true) or couldn't be
    /// (false: failed, or not done within `timeout`, which includes waiting
    /// for messages queued before it). Called from many threads at once;
    /// messages are spoken one after another.
    func speak(_ text: String, timeout: TimeInterval) -> Bool
}

/// Speaks with `/usr/bin/say`, the one way to get the voice chosen in System
/// Settings → Accessibility → Spoken Content, Siri voices included:
/// AVSpeechSynthesizer can't use Siri voices from an app. The text goes to
/// `say` on stdin, never as an argument.
///
/// One message at a time across the whole app, so sandboxes queue instead of
/// talking over each other. Speech only works in a GUI login session, which
/// the app always runs in (and the sandbox users never do; see
/// config/qs-say).
public final class SayCommandSpeaker: Speaker, @unchecked Sendable {
    public static let shared = SayCommandSpeaker()

    private let command: String
    private let turn = DispatchSemaphore(value: 1)

    public init(command: String = "/usr/bin/say") {
        self.command = command
    }

    public func speak(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        guard turn.wait(timeout: deadline) == .success else { return false }
        defer { turn.signal() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
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
        try? input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
        try? input.fileHandleForWriting.close()

        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            exited.wait()
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
