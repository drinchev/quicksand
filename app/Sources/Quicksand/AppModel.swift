import AppKit
import Foundation
import QuicksandCore
import ServiceManagement

/// Everything the status bar shows, refreshed on a timer, plus the broker
/// listeners the app runs.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sandboxes: [SandboxStatus] = []
    @Published private(set) var events: [BrokerEvent] = []
    @Published private(set) var stats = EventStats()
    /// Requests the app itself served (newest last).
    @Published private(set) var connections: [BrokerConnection] = []
    @Published private(set) var isListening = false
    @Published private(set) var listenerError: String?
    @Published private(set) var loginItemError: String?

    let paths: QuicksandPaths
    private let scanner: SandboxScanner
    private let reader: EventLogReader
    private var listeners: [BrokerListener] = []
    private var timer: Timer?
    private let notifier = Notifier()

    private static let listenKey = "runBrokers"
    private static let noticeKey = "notify"

    init(paths: QuicksandPaths = .host()) {
        self.paths = paths
        scanner = SandboxScanner(paths: paths)
        reader = EventLogReader(url: paths.eventsLog)
        UserDefaults.standard.register(defaults: [Self.listenKey: true,
                                                  Self.noticeKey: NoticeMode.all.rawValue])
        if noticeMode != .off { notifier.requestPermission() }
        refresh()
        if UserDefaults.standard.bool(forKey: Self.listenKey) { startBrokers() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Derived

    var activeCount: Int { sandboxes.filter(\.isActive).count }
    var runningRequests: Int {
        connections.filter { if case .running = $0.outcome { return true } else { return false } }.count
    }
    /// Something worth a red icon: the brokers couldn't start, or requests
    /// failed or were rejected in the last hour.
    var needsAttention: Bool { listenerError != nil || stats.problems > 0 }
    /// Sandboxes whose brokers predate the app (their own LaunchAgents, no
    /// event log): a rebuild moves them over.
    var sandboxesNeedingRebuild: [String] {
        sandboxes.filter(\.needsRebuild).map(\.name)
    }
    var eventLogExists: Bool { FileManager.default.fileExists(atPath: paths.eventsLog.path) }

    // MARK: - Refresh

    func refresh() {
        sandboxes = scanner.scan()
        if reader.poll() || events.isEmpty {
            events = reader.events
        }
        stats = EventStats.summarize(events, since: Date().addingTimeInterval(-3600))
    }

    // MARK: - Brokers

    var runBrokers: Bool {
        get { isListening }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.listenKey)
            newValue ? startBrokers() : stopBrokers()
        }
    }

    func startBrokers() {
        guard listeners.isEmpty else { return }
        listenerError = nil
        var started: [BrokerListener] = []
        for kind in BrokerKind.allCases {
            let listener = BrokerListener(kind: kind, paths: paths) { [weak self] conn in
                Task { @MainActor in self?.record(conn) }
            }
            do {
                try listener.start()
                started.append(listener)
            } catch {
                started.forEach { $0.stop() }
                listenerError = "Couldn't open the \(kind.rawValue) socket: \(error)"
                isListening = false
                return
            }
        }
        listeners = started
        isListening = true
    }

    func stopBrokers() {
        listeners.forEach { $0.stop() }
        listeners = []
        isListening = false
    }

    private func record(_ conn: BrokerConnection) {
        let isNew = !connections.contains { $0.id == conn.id }
        if let notice = BrokerNotice.make(for: conn, isNew: isNew, mode: noticeMode) {
            notifier.post(notice, id: conn.id)
        }
        if let i = connections.lastIndex(where: { $0.id == conn.id }) {
            connections[i] = conn
        } else {
            connections.append(conn)
            if connections.count > 500 { connections.removeFirst(connections.count - 500) }
        }
    }

    // MARK: - Notifications

    var noticeMode: NoticeMode {
        get { NoticeMode(rawValue: UserDefaults.standard.string(forKey: Self.noticeKey) ?? "") ?? .all }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.noticeKey)
            if newValue != .off { notifier.requestPermission() }
            objectWillChange.send()
        }
    }
    var notificationsAvailable: Bool { notifier.isAvailable }
    var notificationsDenied: Bool { notifier.denied }

    // MARK: - Login item

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = "Open at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    /// Show events.jsonl in Finder. Before any broker has logged, the file
    /// doesn't exist (and Finder silently does nothing), so open the folder
    /// it will appear in instead.
    func revealEventLog() {
        if eventLogExists {
            NSWorkspace.shared.activateFileViewerSelecting([paths.eventsLog])
        } else {
            try? FileManager.default.createDirectory(at: paths.installDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(paths.installDir)
        }
    }

    func quit() {
        stopBrokers()
        NSApp.terminate(nil)
    }
}
