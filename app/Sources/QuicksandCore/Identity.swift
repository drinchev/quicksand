import Darwin
import Foundation

/// Sandbox names, as qs validates them: 1–16 of `[A-Za-z0-9_-]`.
public enum SandboxName {
    public static func isValid(_ name: String) -> Bool {
        guard (1...16).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x2D || c == 0x5F
        }
    }

    /// `qs-trading` → `trading`; nil for anything that isn't a sandbox user.
    public static func from(username: String) -> String? {
        guard username.hasPrefix("qs-") else { return nil }
        let name = String(username.dropFirst(3))
        return isValid(name) ? name : nil
    }
}

/// The system user directory. A protocol so tests can map their own uid to
/// a sandbox name.
public protocol UserDirectory: Sendable {
    func username(forUID uid: uid_t) -> String?
    func uid(forUsername name: String) -> uid_t?
}

/// getpwuid_r / getpwnam_r: answers only an admin can change.
public struct SystemUserDirectory: UserDirectory {
    public init() {}

    public func username(forUID uid: uid_t) -> String? {
        withPasswd({ pwd, buf, len, result in getpwuid_r(uid, pwd, buf, len, result) }) {
            String(cString: $0.pw_name)
        }
    }

    public func uid(forUsername name: String) -> uid_t? {
        withPasswd({ pwd, buf, len, result in getpwnam_r(name, pwd, buf, len, result) }) { $0.pw_uid }
    }

    private func withPasswd<T>(
        _ lookup: (UnsafeMutablePointer<passwd>, UnsafeMutablePointer<CChar>, Int,
                   UnsafeMutablePointer<UnsafeMutablePointer<passwd>?>) -> Int32,
        _ read: (passwd) -> T
    ) -> T? {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        let rc = buffer.withUnsafeMutableBufferPointer { buf in
            lookup(&pwd, buf.baseAddress!, buf.count, &result)
        }
        guard rc == 0, result != nil else { return nil }
        return read(pwd)
    }
}

/// The uid of the process on the other end of a Unix socket, from the
/// kernel. A sandbox can't forge it.
public func peerUID(of fd: Int32) -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
}

/// Which sandbox a uid belongs to, or nil if it isn't a sandbox user.
public func sandboxName(forUID uid: uid_t, users: UserDirectory) -> String? {
    guard let username = users.username(forUID: uid),
          let name = SandboxName.from(username: username),
          // Round-trip: the name must map back to the same uid.
          users.uid(forUsername: username) == uid
    else { return nil }
    return name
}
