import AVFoundation
import Foundation

/// Something that speaks text aloud on the host.
public protocol Speaker: Sendable {
    /// Speak `text` and return once it was spoken (true) or couldn't be
    /// (false: cancelled, or no answer within `timeout`). Called from many
    /// threads at once; messages are spoken one after another.
    func speak(_ text: String, timeout: TimeInterval) -> Bool
}

/// macOS's speech synthesizer, in the app's own process: no `say` process
/// per message. One synthesizer for the whole app, so messages from all
/// sandboxes queue in it instead of talking over each other.
///
/// Speech only works in a GUI login session, which the app always runs in
/// (and the sandbox users never do; see config/qs-say).
public final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let shared = SystemSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    /// Utterances waiting to finish, with what their caller waits on.
    private var pending: [ObjectIdentifier: Waiter] = [:]

    private final class Waiter {
        let done = DispatchSemaphore(value: 0)
        var spoke = false
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, timeout: TimeInterval) -> Bool {
        let utterance = AVSpeechUtterance(string: text)
        let waiter = Waiter()
        let key = ObjectIdentifier(utterance)
        lock.withLock { pending[key] = waiter }
        // The synthesizer is driven from the main thread; it queues
        // utterances and speaks them in order.
        DispatchQueue.main.async { self.synthesizer.speak(utterance) }
        let finished = waiter.done.wait(timeout: .now() + timeout) == .success
        return lock.withLock {
            pending[key] = nil
            return finished && waiter.spoke
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resolve(utterance, spoke: true)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resolve(utterance, spoke: false)
    }

    private func resolve(_ utterance: AVSpeechUtterance, spoke: Bool) {
        lock.withLock {
            guard let waiter = pending[ObjectIdentifier(utterance)] else { return }
            waiter.spoke = spoke
            waiter.done.signal()
        }
    }
}
