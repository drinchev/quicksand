import Darwin
import Foundation
import os

/// Docker for sandboxes (the `qs-docker` client), inside the app. The policy
/// is `DockerPolicy`; this reads the request, runs the `docker` command it
/// allows with the connection as the container's output (and, for `run`,
/// its input), and reports the exit code.
///
/// Protocol: the client sends ONE line of JSON, e.g.
///   {"v":1,"verb":"run","image":"node:20","cmd":["node","x.js"],
///    "env":{"FOO":"bar"},"workdir":"/Users/Shared/qs-NAME/repos/proj"}
/// Everything after that line is the container's stdin (run only). The
/// broker streams combined output back and ends with a final line
/// "@@qs-docker-exit:<code>@@".
public final class DockerBroker: InProcessBroker, @unchecked Sendable {
    /// A client that hasn't sent its request line by then is dropped.
    public static let readTimeout: TimeInterval = 30
    static let refusedExit: Int32 = 125

    private let paths: QuicksandPaths
    private let hostPath: @Sendable () -> String
    private let ownerUID: uid_t
    private let log = Logger(subsystem: "com.quicksand", category: "docker")

    /// `hostPath` is the PATH `docker` is looked up in (your login shell's).
    public init(paths: QuicksandPaths,
                hostPath: @escaping @Sendable () -> String = { HostEnvironment.cachedLoginShellPath },
                ownerUID: uid_t = getuid()) {
        self.paths = paths
        self.hostPath = hostPath
        self.ownerUID = ownerUID
    }

    /// Docker is opt-in per sandbox: `qs docker NAME` creates the marker.
    public func refusal(for sandbox: String) -> String? {
        checkOwnedFile(paths.dockerMarker(sandbox).path, ownerUID: ownerUID) == .ok ? nil
            : "Docker isn't enabled for this sandbox — on the host, run: qs docker \(sandbox)"
    }

    public func serve(_ client: BrokerClient, sandbox: String) -> Int32 {
        let started = Date()
        let request = client.readLine(maxBytes: DockerPolicy.maxRequestBytes + 1, timeout: Self.readTimeout)

        /// End the request: the exit sentinel first (so the client isn't
        /// kept waiting on the event log), then the event.
        func finish(_ code: Int32, verb: String, target: String, result: String? = nil, reason: String = "") -> Int32 {
            client.write(Data("\n@@qs-docker-exit:\(code)@@\n".utf8))
            record(sandbox, verb: verb, result: result ?? (code == 0 ? "ok" : "error"),
                   exit: code, target: target, reason: reason, started)
            return code == 0 ? 0 : (code & 0xff) << 8
        }
        func fail(_ message: String, verb: String, target: String, result: String = "rejected") -> Int32 {
            log.notice("\(sandbox, privacy: .public): \(message, privacy: .public)")
            client.write(Data("qs-docker: \(message)\n".utf8))
            return finish(Self.refusedExit, verb: verb, target: target, result: result, reason: message)
        }

        let path = hostPath()
        guard let docker = HostEnvironment.find("docker", in: path) else {
            return fail("docker CLI not found on the host — install OrbStack or Docker Desktop, then restart Quicksand.app",
                        verb: "?", target: "", result: "error")
        }
        let workspace = DockerPolicy.resolvePath(paths.workspace(sandbox).path) ?? paths.workspace(sandbox).path

        let plan: DockerPolicy.Plan
        switch DockerPolicy.plan(request, sandbox: sandbox, workspace: workspace) {
        case .success(let p): plan = p
        case .failure(let r): return fail(r.message, verb: r.verb, target: r.target)
        }

        let env = dockerEnvironment(docker: docker, path: path)
        // Never touch a container this sandbox didn't create.
        if let id = plan.ownedID {
            let owner = capture(docker, DockerPolicy.ownerQuery(id), env: env)
            guard owner == sandbox else { return fail("\(plan.verb): no such container", verb: plan.verb, target: id) }
        }

        let status = run(docker, plan.arguments, streamsStdin: plan.streamsStdin, client: client, env: env)
        return finish(status, verb: plan.verb, target: plan.target)
    }

    // MARK: - Running docker

    /// docker execs the credential helper named in ~/.docker/config.json
    /// (docker-credential-osxkeychain, …) through PATH, so put the
    /// directories engines install helpers into first: the CLI's own, its
    /// resolved location (usually a /usr/local/bin link into OrbStack or
    /// Docker Desktop), and /usr/local/bin.
    func dockerEnvironment(docker: String, path: String) -> [String: String] {
        let real = DockerPolicy.resolvePath(docker) ?? docker
        var env = BrokerLauncher.environment()
        env["PATH"] = [(docker as NSString).deletingLastPathComponent,
                       (real as NSString).deletingLastPathComponent,
                       "/usr/local/bin", path].joined(separator: ":")
        return env
    }

    /// Run docker with the connection as stdout and stderr (and stdin for
    /// `run`; /dev/null otherwise). Returns its exit code (128 + signal when
    /// a signal ended it).
    func run(_ docker: String, _ arguments: [String], streamsStdin: Bool,
             client: BrokerClient, env: [String: String]) -> Int32 {
        guard let fd = client.currentFD() else { return Self.refusedExit }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if streamsStdin {
            posix_spawn_file_actions_adddup2(&actions, fd, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, fd, 1)
        posix_spawn_file_actions_adddup2(&actions, fd, 2)
        guard let pid = BrokerLauncher.spawn(docker, [docker] + arguments, env: env, actions: &actions) else {
            return Self.refusedExit
        }
        let status = BrokerLauncher.waitForExit(pid)
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    /// Run docker and return its trimmed stdout (for `inspect`).
    func capture(_ docker: String, _ arguments: [String], env: [String: String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = arguments
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func record(_ sandbox: String, verb: String, result: String, exit: Int32, target: String,
                        reason: String, _ started: Date) {
        let line = try? EventWriter.line(
            broker: BrokerKind.docker.rawValue, sandbox: Data(sandbox.utf8), verb: Data(verb.utf8),
            result: result,
            fields: [("exit", Data(String(exit).utf8)), ("target", Data(target.utf8)), ("reason", Data(reason.utf8))],
            started: started)
        if let line { try? EventWriter.append(line, to: paths.eventsLog) }
    }
}
