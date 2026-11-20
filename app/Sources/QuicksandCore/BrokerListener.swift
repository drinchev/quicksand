import Darwin
import Foundation

/// One request the app handled: who called which broker, and how it ended.
public struct BrokerConnection: Identifiable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case running(pid: pid_t)
        /// The broker exited; `status` is the raw wait status.
        case finished(pid: pid_t, status: Int32)
        /// Turned away before any broker ran.
        case rejected(String)
    }

    public let id: UUID
    public let kind: BrokerKind
    /// nil when the caller wasn't a sandbox user.
    public let sandbox: String?
    public let uid: uid_t?
    public let started: Date
    public var ended: Date?
    public var outcome: Outcome
}

/// Owns one shared broker socket. For each connection it asks the kernel
/// who is calling, maps that to a sandbox, loads that sandbox's spec for
/// this broker, and hands the connection to a freshly spawned bash broker.
/// It never reads what the client sends: all request policy stays in the
/// brokers.
public final class BrokerListener: @unchecked Sendable {
    public let kind: BrokerKind
    public let socketPath: String
    private let paths: QuicksandPaths
    private let users: UserDirectory
    private let ownerUID: uid_t
    private let maxPerSandbox: Int
    private let onUpdate: @Sendable (BrokerConnection) -> Void

    private let queue: DispatchQueue
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    /// Running broker processes per sandbox, to cap what one sandbox can
    /// make the host spawn. Touched only on `queue`.
    private var running: [String: Int] = [:]

    public init(kind: BrokerKind, paths: QuicksandPaths, users: UserDirectory = SystemUserDirectory(),
                ownerUID: uid_t = getuid(), maxPerSandbox: Int = 16,
                onUpdate: @escaping @Sendable (BrokerConnection) -> Void) {
        self.kind = kind
        self.socketPath = paths.socket(kind).path
        self.paths = paths
        self.users = users
        self.ownerUID = ownerUID
        self.maxPerSandbox = maxPerSandbox
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "quicksand.listener.\(kind.rawValue)")
    }

    public enum ListenError: Error, Equatable, CustomStringConvertible {
        case socketDirectory(String)
        case socketPath(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .socketDirectory(let why): return "socket directory: \(why)"
            case .socketPath(let why): return "socket: \(why)"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Create the socket (replacing a stale one of ours) and start accepting.
    public func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            try prepareSocketDirectory(paths.socketDir.path, ownerUID: ownerUID)
            try removeStaleSocket(socketPath, ownerUID: ownerUID)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ListenError.system("socket", errno) }
            do {
                try bindUnix(fd, path: socketPath)
                // Anyone may connect; non-sandbox callers are turned away by uid.
                guard chmod(socketPath, 0o666) == 0 else { throw ListenError.system("chmod", errno) }
                guard listen(fd, 64) == 0 else { throw ListenError.system("listen", errno) }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            } catch {
                close(fd)
                throw error
            }
            listenFD = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptPending() }
            src.setCancelHandler { close(fd) }
            source = src
            src.resume()
        }
    }

    /// Stop accepting and remove the socket. Brokers already running finish.
    public func stop() {
        queue.sync {
            guard listenFD >= 0 else { return }
            source?.cancel()
            source = nil
            listenFD = -1
            unlink(socketPath)
        }
    }

    public var isListening: Bool { queue.sync { listenFD >= 0 } }

    // MARK: - Per connection (on `queue`)

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }  // EAGAIN: drained
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        // An accepted socket inherits O_NONBLOCK from the listener on macOS;
        // the bash brokers need ordinary blocking reads.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let uid = peerUID(of: client)
        let sandbox = uid.flatMap { sandboxName(forUID: $0, users: users) }
        var conn = BrokerConnection(id: UUID(), kind: kind, sandbox: sandbox, uid: uid,
                                    started: Date(), ended: nil, outcome: .rejected(""))

        func reject(_ message: String) {
            let reply = kind.rejection(message)
            reply.withUnsafeBytes { buf in _ = write(client, buf.baseAddress, buf.count) }
            close(client)
            conn.outcome = .rejected(message)
            conn.ended = Date()
            onUpdate(conn)
        }

        guard let name = sandbox else { return reject("this socket only serves quicksand sandboxes") }
        guard running[name, default: 0] < maxPerSandbox else {
            return reject("too many concurrent \(kind.rawValue) requests from this sandbox — try again shortly")
        }

        let spec: BrokerSpec
        switch BrokerSpec.load(kind, sandbox: name, paths: paths, ownerUID: ownerUID) {
        case .success(let s):
            spec = s
        case .failure(.missing):
            return reject(kind == .docker
                ? "Docker isn't enabled for this sandbox — on the host, run: qs docker \(name)"
                : "the \(kind.rawValue) broker isn't set up for this sandbox — on the host, run: qs build \(name)")
        case .failure(let error):
            NSLog("quicksand: refusing \(kind.rawValue) broker for \(name): \(error)")
            return reject("the host's \(kind.rawValue) broker setup for this sandbox looks wrong — on the host, run: qs build \(name) --rebuild")
        }

        let pid: pid_t
        do {
            pid = try BrokerLauncher.spawn(spec, connection: client)
        } catch {
            return reject("the host couldn't start the \(kind.rawValue) broker")
        }
        close(client)  // the broker holds its own copies
        running[name, default: 0] += 1
        conn.outcome = .running(pid: pid)
        onUpdate(conn)

        let thread = Thread { [weak self] in
            let status = BrokerLauncher.waitForExit(pid)
            guard let self else { return }
            self.queue.async {
                self.running[name, default: 1] -= 1
                conn.outcome = .finished(pid: pid, status: status)
                conn.ended = Date()
                self.onUpdate(conn)
            }
        }
        thread.name = "quicksand.broker.\(pid)"
        thread.start()
    }
}

// MARK: - Socket helpers

/// The socket directory must be a real directory owned by the host user and
/// writable by no one else; otherwise someone could swap the socket for one
/// of their own. Created 0755 if missing.
func prepareSocketDirectory(_ path: String, ownerUID: uid_t) throws {
    if mkdir(path, 0o755) != 0 && errno != EEXIST {
        throw BrokerListener.ListenError.system("mkdir", errno)
    }
    var st = stat()
    guard lstat(path, &st) == 0 else { throw BrokerListener.ListenError.system("lstat", errno) }
    guard (st.st_mode & S_IFMT) == S_IFDIR else {
        throw BrokerListener.ListenError.socketDirectory("\(path) is not a directory")
    }
    guard st.st_uid == ownerUID else {
        throw BrokerListener.ListenError.socketDirectory("\(path) is not owned by the host user")
    }
    guard st.st_mode & 0o022 == 0 else {
        throw BrokerListener.ListenError.socketDirectory("\(path) is writable by group or others")
    }
}

/// Remove a socket left behind by an earlier run — only if it is a socket
/// we own. Anything else at that path is someone else's and is left alone.
func removeStaleSocket(_ path: String, ownerUID: uid_t) throws {
    var st = stat()
    guard lstat(path, &st) == 0 else { return }
    guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == ownerUID else {
        throw BrokerListener.ListenError.socketPath("\(path) exists and isn't a socket of ours")
    }
    unlink(path)
}

func bindUnix(_ fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw BrokerListener.ListenError.socketPath("path too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { throw BrokerListener.ListenError.system("bind", errno) }
}

/// Connect to a Unix socket (used by the tests, and handy for probes).
public func connectUnix(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { close(fd); return nil }
    return fd
}
