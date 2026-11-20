import AppKit
import QuicksandCore
import SwiftUI

/// The panel that drops down from the status-bar icon.
struct MenuContent: View {
    static let sandboxRowHeight: CGFloat = 34

    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statTiles
            Divider()
            section("Sandboxes") {
                if model.sandboxes.isEmpty {
                    Text("No sandboxes on this Mac yet.").foregroundStyle(.secondary)
                } else {
                    // An explicit height: the panel sizes to its content's ideal
                    // size, and a ScrollView's ideal height is zero, so with only
                    // a max height the list collapsed to nothing.
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.sandboxes) { box in
                                SandboxRow(box: box, last: model.stats.lastBySandbox[box.name])
                                    .frame(height: Self.sandboxRowHeight - 6, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.sandboxes.count) * Self.sandboxRowHeight, 300))
                }
            }
            Divider()
            section("Recent requests") {
                let recent = model.events.suffix(6).reversed()
                let stale = model.sandboxesNeedingRebuild
                if !stale.isEmpty {
                    Text("\(stale.count) of \(model.sandboxes.count) sandboxes still use their old per-sandbox brokers, which this app doesn't serve or log. Any qs command for a sandbox rebuilds it and moves it over, e.g. qs build \(stale[0]).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(stale.joined(separator: ", "))
                }
                if recent.isEmpty {
                    Text("Nothing yet. Brokers log here as sandboxes use them.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(recent)) { EventRow(event: $0) }
                    }
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quicksand").font(.headline)
                Spacer()
                Toggle("Run brokers", isOn: Binding(get: { model.runBrokers },
                                                     set: { model.runBrokers = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isListening ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.isListening
                     ? "Serving Docker, credentials and speech at \(model.paths.socketDir.path)"
                     : "Brokers are off: sandboxes can't use Docker, credential refresh or speech")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = model.listenerError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var statTiles: some View {
        HStack(spacing: 8) {
            StatTile(title: "Active", value: "\(model.activeCount)/\(model.sandboxes.count)")
            StatTile(title: "Requests · 1h", value: "\(model.stats.total)")
            StatTile(title: "Problems · 1h", value: "\(model.stats.problems)",
                     tint: model.stats.problems > 0 ? .orange : nil)
            StatTile(title: "Running", value: "\(model.runningRequests)")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Activity…") {
                    openWindow(id: "activity")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button(model.eventLogExists ? "Show event log" : "Open log folder") { model.revealEventLog() }
                    .help(model.paths.eventsLog.path)
                Spacer()
                Button("Quit") { model.quit() }
            }
            HStack {
                Text("Notify")
                Picker("Notify", selection: Binding(get: { model.noticeMode },
                                                    set: { model.noticeMode = $0 })) {
                    Text("Every request").tag(NoticeMode.all)
                    Text("Problems").tag(NoticeMode.problems)
                    Text("Off").tag(NoticeMode.off)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .help("Every request: a banner whenever a sandbox (or anyone) connects to a broker. Problems: only refused or failed requests.")
            }
            .controlSize(.small)
            .disabled(!model.notificationsAvailable)
            if model.notificationsDenied && model.noticeMode != .off {
                Text("Notifications are off for Quicksand in System Settings → Notifications.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin },
                                                  set: { model.opensAtLogin = $0 }))
                .controlSize(.small)
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SandboxRow: View {
    let box: SandboxStatus
    let last: BrokerEvent?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(box.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .help(activityHelp)
            VStack(alignment: .leading, spacing: 1) {
                Text(box.name).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if box.sessionCount > 0 {
                Chip(text: box.sessionCount == 1 ? "1 session" : "\(box.sessionCount) sessions")
                    .help("Shells or agents started with qs that are still open")
            }
            if box.brokers.contains(.docker) {
                Chip(text: "Docker").help("Docker is enabled for this sandbox (qs docker)")
            }
            if let age = box.gcpTokenAge {
                Chip(text: age > 3600 ? "GCP expired" : "GCP \(shortAge(age))", tint: age > 3600 ? .orange : nil)
                    .help(age > 3600
                          ? "The staged GCP token is over an hour old; qs-auth-refresh in the sandbox gets a new one"
                          : "A GCP token is staged; it was refreshed \(shortAge(age)) ago and lasts about an hour")
            }
            if box.opTokenStaged {
                Chip(text: "1Password").help("A 1Password service-account token is staged for this sandbox")
            }
        }
        .font(.caption)
    }

    /// "Active · claude, zsh · docker run 3m ago" or "Idle".
    private var subtitle: String {
        var parts: [String] = []
        if box.isActive {
            let names = Array(Set(box.processes)).sorted()
            parts.append(names.isEmpty ? "Active" : "Active · " + names.prefix(3).joined(separator: ", "))
        } else {
            parts.append("Idle")
        }
        if let last, let date = last.date {
            parts.append("\(last.broker) \(last.verb) \(shortAge(Date().timeIntervalSince(date))) ago")
        }
        return parts.joined(separator: " · ")
    }

    private var activityHelp: String {
        guard box.isActive else { return "Idle" }
        let names = Array(Set(box.processes)).sorted()
        let shown = names.prefix(8).joined(separator: ", ")
        let programs = names.isEmpty ? "" : "Running: \(shown)\(names.count > 8 ? ", …" : "")"
        let sessions = box.sessionCount > 0 ? "\(box.sessionCount) open session(s)" : ""
        return [sessions, programs].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A small labeled tag on a sandbox row.
struct Chip: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tint ?? .secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(tint ?? .secondary)
    }
}

struct EventRow: View {
    let event: BrokerEvent

    var body: some View {
        HStack(spacing: 6) {
            if let date = event.date {
                Text(date, format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: event.kind?.symbol ?? "questionmark")
                .frame(width: 14)
            Text(event.sandbox).fontWeight(.medium)
            Text(event.summary)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            ResultBadge(result: event.result)
        }
        .font(.caption)
        .help(event.reason ?? event.summary)
    }
}

struct ResultBadge: View {
    let result: String

    var body: some View {
        Text(result)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch result {
        case "ok": return .green
        case "error": return .red
        case "rejected": return .orange
        case "shared": return .blue
        default: return .secondary
        }
    }
}

extension BrokerKind {
    var symbol: String {
        switch self {
        case .docker: return "shippingbox"
        case .auth: return "key"
        case .say: return "speaker.wave.2"
        }
    }
}

func shortAge(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
