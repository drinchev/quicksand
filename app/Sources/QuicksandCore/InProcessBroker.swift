import Darwin
import Foundation

/// A broker that runs inside the app instead of as a bash script per
/// connection. The listener has already identified the sandbox (from the
/// caller's uid) and applied the per-sandbox cap; the broker only serves.
public protocol InProcessBroker: Sendable {
    /// nil when `sandbox` may use this broker, else why not (recorded,
    /// notified and sent to the client in the broker's protocol).
    func refusal(for sandbox: String) -> String?

    /// Serve one connection. Runs on its own thread and may block. Returns a
    /// wait-style status like a broker process would (0: fine, code << 8:
    /// failed), so the app shows both kinds the same way.
    func serve(_ client: BrokerClient, sandbox: String) -> Int32
}

/// One accepted connection, owned by an in-process broker. Closed when the
/// broker closes it or when this object goes away.
public final class BrokerClient: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }
    deinit { close() }

    /// Read up to the first newline (not included), at most `maxBytes`
    /// bytes, giving up after `timeout`. Like bash's `read -r -t -n`, what
    /// arrived before EOF or the deadline is returned. Reads one byte at a
    /// time so nothing after the line is consumed.
    public func readLine(maxBytes: Int, timeout: TimeInterval) -> Data {
        var line = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while line.count < maxBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let fd = currentFD() else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            var byte: UInt8 = 0
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1, byte != UInt8(ascii: "\n") else { break }
            line.append(byte)
        }
        return line
    }

    /// Write everything (best effort: a client that hung up gets EPIPE —
    /// the socket has SO_NOSIGPIPE — and the rest is dropped).
    @discardableResult
    public func write(_ data: Data) -> Bool {
        guard let fd = currentFD() else { return false }
        return data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func currentFD() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0 ? fd : nil
    }
}
