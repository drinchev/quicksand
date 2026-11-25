import Darwin
import Foundation

/// What a sandbox may ask the host's Docker engine to do, and the exact
/// `docker` command each request becomes. Pure: no Docker, no sockets; the
/// broker (`DockerBroker`) runs what this returns.
///
/// A sandbox never sees the Docker socket: raw socket access is
/// host-user-equivalent (`-v /Users/you:/host` would read your home). It
/// sends one JSON line instead, picking a verb and a few validated values;
/// the policy owns every flag. Each client value becomes exactly one argv
/// element after a literal docker subcommand, and the patterns forbid a
/// leading `-`, so nothing can turn into an option.
///
/// What the policy can and cannot contain: a malicious Dockerfile or image
/// stays inside Docker's own boundaries (COPY/ADD are confined to the
/// validated build context; RUN steps and containers only see the workspace
/// mount, with _quicksand/ masked out). A container-escape bug in the engine
/// itself is out of scope: enabling Docker adds the engine — and its VM's
/// macOS file sharing — to the sandbox's trusted computing base.
public enum DockerPolicy {
    public static let maxRequestBytes = 65_536
    public static let labelKey = "quicksand.sandbox"
    public static let verbs = ["run", "build", "pull", "ps", "logs", "stop"]

    /// A request the policy allows: the full `docker` argv (without the
    /// program itself), and whether the rest of the connection becomes the
    /// container's stdin. `ownedID` must be checked to carry this sandbox's
    /// label before running (logs/stop).
    public struct Plan: Equatable, Sendable {
        public var verb: String
        public var target: String
        public var arguments: [String]
        public var streamsStdin: Bool
        public var ownedID: String?
    }

    /// Why a request is refused. `verb`/`target` are what it asked for, for
    /// the event log.
    public struct Refusal: Error, Equatable, Sendable {
        public var message: String
        public var verb: String
        public var target: String
    }

    static let imagePattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,255}$"#)
    static let idPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$"#)
    static let envKeyPattern = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `workspace` must already be resolved (realpath); `resolve` resolves a
    /// client path through symlinks and `..`, or returns nil if it doesn't
    /// exist.
    public static func plan(_ request: Data, sandbox: String, workspace: String,
                            resolve: (String) -> String? = resolvePath) -> Result<Plan, Refusal> {
        func refuse(_ message: String, _ verb: String = "?", _ target: String = "") -> Result<Plan, Refusal> {
            .failure(Refusal(message: message, verb: verb, target: target))
        }
        guard request.count <= maxRequestBytes else { return refuse("request too large") }
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let verb = object["verb"] as? String
        else { return refuse("unparseable request") }

        let label = "\(labelKey)=\(sandbox)"
        let privateDir = workspace + "/_quicksand"

        /// The resolved path when `raw` is inside the workspace.
        func underWorkspace(_ raw: String) -> String? {
            guard let p = resolve(raw), p == workspace || p.hasPrefix(workspace + "/") else { return nil }
            return p
        }
        /// A string value; nil when absent (missing or null), and
        /// `.some(nil)` when present but not a string.
        func string(_ key: String) -> String?? {
            guard let value = object[key], !(value is NSNull) else { return .none }
            return .some(value as? String)
        }

        switch verb {
        case "run":
            guard case .some(let imageValue) = string("image") else { return refuse("run: missing image", verb) }
            guard let image = imageValue, matches(imagePattern, image) else {
                return refuse("run: bad image ref", verb, imageValue ?? "")
            }
            var workdir = workspace
            if case .some(let w) = string("workdir") {
                guard let w else { return refuse("run: workdir must be under \(workspace)", verb, image) }
                if !w.isEmpty {
                    guard let resolved = underWorkspace(w) else {
                        return refuse("run: workdir must be under \(workspace)", verb, image)
                    }
                    workdir = resolved
                }
            }
            var args = ["run", "--rm", "-i",
                        "--label", label,
                        "--cap-drop", "ALL",
                        "--security-opt", "no-new-privileges",
                        "--pids-limit", "512", "--memory", "4g", "--cpus", "4",
                        "--network", "bridge",
                        "-v", "\(workspace):\(workspace)",
                        "-w", workdir,
                        // Shadow _quicksand with an empty anonymous volume
                        // (reaped by --rm): it holds live credentials.
                        // Containers — often third-party images — get the
                        // workspace, never the sandbox's secrets.
                        "-v", privateDir]
            if let env = object["env"], !(env is NSNull) {
                guard let env = env as? [String: Any] else { return refuse("run: bad env", verb, image) }
                for key in env.keys.sorted() {
                    guard matches(envKeyPattern, key) else { return refuse("run: bad env name", verb, image) }
                    guard let value = env[key] as? String else { return refuse("run: bad env", verb, image) }
                    args += ["-e", "\(key)=\(value)"]
                }
            }
            args.append(image)
            if let cmd = object["cmd"], !(cmd is NSNull) {
                guard let cmd = cmd as? [Any], let words = cmd as? [String] else {
                    return refuse("run: bad cmd", verb, image)
                }
                args += words
            }
            return .success(Plan(verb: verb, target: image, arguments: args, streamsStdin: true, ownedID: nil))

        case "build":
            guard case .some(let tagValue) = string("tag") else { return refuse("build: missing tag", verb) }
            let namespace = "qs-\(sandbox)/"
            guard let tag = tagValue, tag.hasPrefix(namespace), matches(imagePattern, tag) else {
                return refuse("build: tag must live under \(namespace) (can't clobber host images)", verb, tagValue ?? "")
            }
            guard case .some(let contextValue) = string("context") else { return refuse("build: missing context", verb, tag) }
            guard let raw = contextValue, let context = underWorkspace(raw) else {
                return refuse("build: context must be under \(workspace)", verb, tag)
            }
            // COPY/ADD can reach anything in the context, so the workspace
            // root and _quicksand (live credentials) must never BE it.
            guard context != workspace else {
                return refuse("build: context must be a subdirectory of the workspace, not its root (it would include _quicksand credentials)", verb, tag)
            }
            guard context != privateDir, !context.hasPrefix(privateDir + "/") else {
                return refuse("build: context must not be under _quicksand", verb, tag)
            }
            var args = ["build", "--label", label, "-t", tag]
            if case .some(let d) = string("dockerfile") {
                guard let d else { return refuse("build: dockerfile must be under \(workspace)", verb, tag) }
                if !d.isEmpty {
                    guard let file = underWorkspace(d) else {
                        return refuse("build: dockerfile must be under \(workspace)", verb, tag)
                    }
                    args += ["-f", file]
                }
            }
            args.append(context)
            return .success(Plan(verb: verb, target: tag, arguments: args, streamsStdin: false, ownedID: nil))

        case "pull":
            guard case .some(let imageValue) = string("image") else { return refuse("pull: missing image", verb) }
            guard let image = imageValue, matches(imagePattern, image) else {
                return refuse("pull: bad image ref", verb, imageValue ?? "")
            }
            return .success(Plan(verb: verb, target: image, arguments: ["pull", image], streamsStdin: false, ownedID: nil))

        case "ps":
            return .success(Plan(verb: verb, target: "", arguments: ["ps", "-a", "--filter", "label=\(label)"],
                                 streamsStdin: false, ownedID: nil))

        case "logs", "stop":
            guard case .some(let idValue) = string("id") else { return refuse("\(verb): missing id", verb) }
            guard let id = idValue, matches(idPattern, id) else {
                return refuse("\(verb): bad container id", verb, idValue ?? "")
            }
            return .success(Plan(verb: verb, target: id, arguments: [verb, id], streamsStdin: false, ownedID: id))

        default:
            return refuse("unknown verb '\(verb)' (allowed: \(verbs.joined(separator: " ")))", verb)
        }
    }

    /// The `docker inspect` arguments that print a container's sandbox label.
    public static func ownerQuery(_ id: String) -> [String] {
        ["inspect", "-f", "{{ index .Config.Labels \"\(labelKey)\" }}", id]
    }

    /// realpath(3), or nil when the path doesn't exist.
    public static func resolvePath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
