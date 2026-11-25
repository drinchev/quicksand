import Darwin
import Foundation
import os

/// Credential refresh for sandboxes (the `qs-auth-refresh` client), inside
/// the app.
///
/// `qs shell` / `qs claude` run the auth providers (libexec/qs-auth-*) on the
/// host just before entering a sandbox: the ~1 h GCP token is re-minted, the
/// 1Password token is read from the host's own 1Password. A session that
/// doesn't start from qs (an SSH login) or outlives its token has no such
/// moment; this broker is that moment, on demand. It runs in the host user's
/// GUI session, where 1Password's app integration and the gcloud login live.
///
/// The client is untrusted, so it gets to say exactly one thing, `refresh`,
/// and nothing it sends reaches a command line. The sandbox comes from the
/// caller's uid: all a hostile client can do is ask the host to re-stage
/// that sandbox's own credentials, which a launch does anyway.
///
/// Protocol: the client sends `refresh`; the broker answers with the
/// providers' messages, one per line, then `done`. No `done` means the
/// refresh didn't complete.
public final class AuthBroker: InProcessBroker, @unchecked Sendable {
    public static let maxRequestBytes = 64
    public static let readTimeout: TimeInterval = 10
    /// A provider can block on something only a person can clear (a
    /// 1Password approval on the host), so each one gets a deadline.
    public static let defaultProviderTimeout: TimeInterval = 30
    static let maxOutputBytes = 4000
    static let maxReplyLineBytes = 500

    private let paths: QuicksandPaths
    /// Where the providers are: the app's own copy (Contents/Resources/
    /// quicksand/libexec), nil when it can't be found.
    private let libexec: URL?
    /// The PATH providers run with (where `op` and `gcloud` are).
    private let hostPath: @Sendable () -> String
    private let providerTimeout: TimeInterval
    private let ownerUID: uid_t
    private let log = Logger(subsystem: "com.quicksand", category: "auth")

    /// One refresh per sandbox at a time. A request that arrives while one
    /// runs waits for it and reuses its result instead of refreshing again.
    private let lock = NSLock()
    private var inFlight: [String: DispatchGroup] = [:]

    public init(paths: QuicksandPaths,
                libexec: URL? = HostEnvironment.quicksandDir()?.appendingPathComponent("libexec"),
                hostPath: @escaping @Sendable () -> String = { HostEnvironment.cachedLoginShellPath },
                providerTimeout: TimeInterval = defaultProviderTimeout,
                ownerUID: uid_t = getuid()) {
        self.paths = paths
        self.libexec = libexec
        self.hostPath = hostPath
        self.providerTimeout = providerTimeout
        self.ownerUID = ownerUID
    }

    /// Every built sandbox may refresh; `qs build` writes the install marker.
    public func refusal(for sandbox: String) -> String? {
        checkOwnedFile(paths.installMarker(sandbox).path, ownerUID: ownerUID) == .ok ? nil
            : "this sandbox isn't built — on the host, run: qs build \(sandbox)"
    }

    public func serve(_ client: BrokerClient, sandbox: String) -> Int32 {
        let started = Date()
        let request = client.readLine(maxBytes: Self.maxRequestBytes, timeout: Self.readTimeout)
        guard request == Data("refresh".utf8) else {
            log.notice("\(sandbox, privacy: .public): rejected request")
            client.write(Self.replyLine("qs-auth-broker: unknown request"))
            record(sandbox, verb: request, result: "rejected", fields: [("reason", "unknown request")], started)
            return 0
        }

        lock.lock()
        if let running = inFlight[sandbox] {
            lock.unlock()
            // Long enough for the three providers to hit their deadlines,
            // and shorter than qs-auth-refresh's own 100 s wait.
            _ = running.wait(timeout: .now() + providerTimeout * 3 + 5)
            log.info("\(sandbox, privacy: .public): refresh shared with a concurrent request")
            client.write(Self.replyLine("done"))
            record(sandbox, verb: request, result: "shared", fields: [], started)
            return 0
        }
        let mine = DispatchGroup()
        mine.enter()
        inFlight[sandbox] = mine
        lock.unlock()
        defer {
            lock.withLock { inFlight[sandbox] = nil }
            mine.leave()
        }

        guard let libexec, LegacyCLI.isDirectory(libexec.path) else {
            log.error("provider directory missing: \(self.libexec?.path ?? "none", privacy: .public)")
            client.write(Self.replyLine("quicksand's auth providers were not found in Quicksand.app — reinstall it on the host (app/scripts/install.sh)"))
            record(sandbox, verb: request, result: "error", fields: [("reason", "provider directory missing")], started)
            return 1 << 8
        }

        var outcomes: [String] = []
        for provider in Self.providers(in: libexec) {
            let name = String(provider.lastPathComponent.dropFirst("qs-auth-".count))
            let run = runProvider(provider, sandbox: sandbox)
            for line in run.output.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                log.info("\(sandbox, privacy: .public) \(name, privacy: .public): \(String(decoding: line, as: UTF8.self), privacy: .public)")
                client.write(Self.replyLine(Data(line)))
            }
            switch run.outcome {
            case .exited(0):
                outcomes.append("\(name)=ok")
            case .exited(let code):
                outcomes.append("\(name)=exit \(code)")
            case .timedOut:
                client.write(Self.replyLine("WARNING: the host's \(name) credential refresh gave up after \(Int(providerTimeout))s — it may be waiting for you to approve or unlock something on the host."))
                outcomes.append("\(name)=timeout")
            case .notStarted:
                outcomes.append("\(name)=error")
            }
            log.info("\(sandbox, privacy: .public) \(name, privacy: .public): \(outcomes.last ?? "", privacy: .public)")
        }
        client.write(Self.replyLine("done"))

        let ok = outcomes.allSatisfy { $0.hasSuffix("=ok") }
        record(sandbox, verb: request, result: ok ? "ok" : "error",
               fields: [("providers", outcomes.joined(separator: ","))], started)
        return ok ? 0 : 1 << 8
    }

    // MARK: - Providers

    /// The executable `qs-auth-*` files in `dir`, in name order.
    static func providers(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("qs-auth-") }.sorted()
            .map { dir.appendingPathComponent($0) }
            .filter { LegacyCLI.isRegularFile($0.path) && access($0.path, X_OK) == 0 }
    }

    enum Outcome: Equatable {
        case exited(Int32)
        case timedOut
        case notStarted
    }

    /// Run one provider's `refresh` with the environment contract qs gives
    /// it (run_auth_provider in qs.bash), in a process group of its own so a
    /// deadline stops everything it started. Its output goes to a file, not
    /// the socket: a child that outlives its deadline must not hold the
    /// client's connection open.
    func runProvider(_ script: URL, sandbox: String) -> (output: Data, outcome: Outcome) {
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("qs-auth-\(UUID().uuidString)").path
        let outFD = open(outPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard outFD >= 0 else { return (Data(), .notStarted) }
        unlink(outPath)
        defer { close(outFD) }

        var env = BrokerLauncher.environment()
        env["PATH"] = hostPath()
        env["QS_SANDBOX_NAME"] = sandbox
        env["QS_PRIVATE_DIR"] = paths.privateDir(sandbox).path
        env["QS_INSTALL_DIR"] = paths.installDir.path
        env["QS_VERBOSE"] = "0"

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFD, 1)
        posix_spawn_file_actions_adddup2(&actions, outFD, 2)
        guard let pid = BrokerLauncher.spawn(script.path, [script.path, "refresh"], env: env,
                                             actions: &actions, ownGroup: true)
        else { return (Data(), .notStarted) }

        let outcome = Self.wait(pid, timeout: providerTimeout)
        var output = Data(count: Self.maxOutputBytes)
        let n = output.withUnsafeMutableBytes { pread(outFD, $0.baseAddress, Self.maxOutputBytes, 0) }
        output.count = max(0, n)
        return (output, outcome)
    }

    /// Wait for `pid` until `timeout`; past it, stop its whole process group
    /// (TERM, then KILL a second later) and reap it.
    static func wait(_ pid: pid_t, timeout: TimeInterval) -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return .exited(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) }
            if r == -1 && errno != EINTR { return .exited(-1) }
            usleep(20_000)
        }
        kill(-pid, SIGTERM)
        for _ in 0..<50 {
            if waitpid(pid, &status, WNOHANG) == pid { break }
            usleep(20_000)
        }
        kill(-pid, SIGKILL)
        _ = waitpid(pid, &status, WNOHANG)
        return .timedOut
    }

    // MARK: - Replies and events

    /// One line for the client: control characters stripped and capped —
    /// provider output is host-generated, but it lands in a sandbox terminal.
    static func replyLine(_ text: String) -> Data { replyLine(Data(text.utf8)) }

    static func replyLine(_ raw: Data) -> Data {
        var kept = Data(raw.filter { $0 >= 0x20 && $0 != 0x7f }.prefix(maxReplyLineBytes))
        for _ in 0..<3 where String(data: kept, encoding: .utf8) == nil && !kept.isEmpty {
            kept.removeLast()
        }
        return kept + Data("\n".utf8)
    }

    private func record(_ sandbox: String, verb: Data, result: String, fields: [(String, String)], _ started: Date) {
        let line = try? EventWriter.line(broker: BrokerKind.auth.rawValue, sandbox: Data(sandbox.utf8),
                                         verb: verb, result: result,
                                         fields: fields.map { ($0.0, Data($0.1.utf8)) }, started: started)
        if let line { try? EventWriter.append(line, to: paths.eventsLog) }
    }
}
