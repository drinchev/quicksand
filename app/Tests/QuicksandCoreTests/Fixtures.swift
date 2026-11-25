import Darwin
import Foundation
@testable import QuicksandCore

/// A throwaway quicksand tree under /tmp (short: Unix socket paths are
/// capped at 104 bytes), with every path the app reads pointed into it.
final class Fixture {
    let root: URL
    let paths: QuicksandPaths

    init() throws {
        let id = UUID().uuidString.prefix(8)
        root = URL(fileURLWithPath: "/tmp/qst-\(id)")
        paths = QuicksandPaths(
            usersDir: root.appendingPathComponent("Users"),
            sharedDir: root.appendingPathComponent("Shared"),
            installDir: root.appendingPathComponent("install"),
            socketDir: root.appendingPathComponent("sock")
        )
        for dir in [paths.usersDir, paths.sharedDir, paths.installDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        chmod(root.path, 0o755)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// Maps uids to usernames from a table, so a test's own uid can play a
/// sandbox user.
struct FakeUsers: UserDirectory {
    var byUID: [uid_t: String]

    func username(forUID uid: uid_t) -> String? { byUID[uid] }
    func uid(forUsername name: String) -> uid_t? { byUID.first { $0.value == name }?.key }
}

/// Collects listener updates from its queue.
final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [BrokerConnection] = []

    func add(_ c: BrokerConnection) { lock.withLock { all.append(c) } }
    var list: [BrokerConnection] { lock.withLock { all } }

    /// Wait (up to `timeout`) for an update matching `predicate`.
    func wait(timeout: TimeInterval = 5, for predicate: (BrokerConnection) -> Bool) -> BrokerConnection? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = list.first(where: predicate) { return hit }
            usleep(20_000)
        }
        return nil
    }
}

/// Connect, send `request` (if any), half-close, and read until EOF.
func exchange(_ socketPath: String, _ request: String?) -> String? {
    guard let fd = connectUnix(path: socketPath) else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    if let request {
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
    shutdown(fd, SHUT_WR)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}
