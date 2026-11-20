import Darwin
import Foundation

/// How to run one broker for one sandbox: the program arguments and
/// environment qs renders into that sandbox's spec plist (the same keys a
/// LaunchAgent has, so the app starts each broker exactly as launchd did).
/// "Is the docker broker enabled for NAME" is whether qs rendered the spec.
public struct BrokerSpec: Equatable, Sendable {
    public let kind: BrokerKind
    public let sandbox: String
    public let arguments: [String]
    public let environment: [String: String]

    public enum LoadError: Error, Equatable, Sendable {
        case missing
        /// A file in the chain could be changed by someone other than the
        /// user running the app, or isn't a plain file.
        case unsafe(String)
        case malformed(String)
    }

    /// Load and check `kind`'s spec for `sandbox` (see `QuicksandPaths.spec`).
    ///
    /// The plist decides what runs as the host user, so it — and the broker
    /// script it names — must be regular files owned by `ownerUID` and
    /// writable by no one else. The plist must also name this sandbox, so a
    /// misfiled plist can't hand one sandbox another's broker.
    public static func load(_ kind: BrokerKind, sandbox: String, paths: QuicksandPaths,
                            ownerUID: uid_t = getuid()) -> Result<BrokerSpec, LoadError> {
        let url = paths.spec(kind, sandbox: sandbox)
        switch checkOwnedFile(url.path, ownerUID: ownerUID) {
        case .missing: return .failure(.missing)
        case .unsafe(let why): return .failure(.unsafe("\(url.lastPathComponent): \(why)"))
        case .ok: break
        }
        guard let data = FileManager.default.contents(atPath: url.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .failure(.malformed("\(url.lastPathComponent): not a property list")) }

        guard plist["Label"] as? String == kind.label(for: sandbox) else {
            return .failure(.malformed("\(url.lastPathComponent): label doesn't match"))
        }
        guard let args = plist["ProgramArguments"] as? [String], args.count >= 3,
              args[0].hasPrefix("/"), args[1].hasPrefix("/"), args[2] == sandbox
        else { return .failure(.malformed("\(url.lastPathComponent): unexpected ProgramArguments")) }

        // args[1] is the staged broker script, run by args[0] (/bin/bash).
        switch checkOwnedFile(args[1], ownerUID: ownerUID) {
        case .missing: return .failure(.malformed("broker script \(args[1]) is missing"))
        case .unsafe(let why): return .failure(.unsafe("\(args[1]): \(why)"))
        case .ok: break
        }

        let env = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        return .success(BrokerSpec(kind: kind, sandbox: sandbox, arguments: args, environment: env))
    }
}

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
