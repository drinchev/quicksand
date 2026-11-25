import Darwin
import Foundation

/// How the brokers trust a host-side file qs writes (the install and Docker
/// markers): it decides what a sandbox may do, so only the host user may
/// have written it.
enum FileCheck: Equatable {
    case ok, missing
    case unsafe(String)
}

/// A regular file (not a symlink) owned by `ownerUID`, not group- or
/// world-writable.
func checkOwnedFile(_ path: String, ownerUID: uid_t) -> FileCheck {
    var st = stat()
    guard lstat(path, &st) == 0 else { return errno == ENOENT ? .missing : .unsafe("can't stat") }
    guard (st.st_mode & S_IFMT) == S_IFREG else { return .unsafe("not a regular file") }
    guard st.st_uid == ownerUID else { return .unsafe("not owned by the host user") }
    guard st.st_mode & 0o022 == 0 else { return .unsafe("writable by group or others") }
    return .ok
}
