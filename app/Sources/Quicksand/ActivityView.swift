import QuicksandCore
import SwiftUI

/// The full activity window: every broker request from the event log, and
/// the connections the app itself served, with filters.
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case requests = "Requests"
        case connections = "Connections"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .requests
    @State private var sandbox = "All"
    @State private var broker = "All"
    @State private var problemsOnly = false
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            filters
                .padding(10)
            Divider()
            switch tab {
            case .requests: requestsTable
            case .connections: connectionsTable
            }
        }
        .frame(minWidth: 760, minHeight: 360)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Picker("Sandbox", selection: $sandbox) {
                Text("All").tag("All")
                ForEach(sandboxNames, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 180)
            Picker("Broker", selection: $broker) {
                Text("All").tag("All")
                ForEach(BrokerKind.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .frame(width: 150)
            Toggle("Problems only", isOn: $problemsOnly)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var sandboxNames: [String] {
        Set(model.sandboxes.map(\.name)).union(model.events.map(\.sandbox)).sorted()
    }

    // MARK: Requests (event log)

    private var filteredEvents: [BrokerEvent] {
        model.events.reversed().filter { e in
            (sandbox == "All" || e.sandbox == sandbox)
                && (broker == "All" || e.broker == broker)
                && (!problemsOnly || e.isProblem)
                && (search.isEmpty || [e.summary, e.reason ?? "", e.sandbox]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var requestsTable: some View {
        Table(filteredEvents) {
            TableColumn("Time") { e in
                Text(e.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? e.ts)
                    .monospacedDigit()
            }
            .width(min: 150, ideal: 170)
            TableColumn("Sandbox", value: \.sandbox).width(min: 80, ideal: 110)
            TableColumn("Broker") { e in
                Label(e.broker, systemImage: e.kind?.symbol ?? "questionmark")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Request") { e in
                Text(e.summary).lineLimit(1).truncationMode(.middle).help(e.summary)
            }
            TableColumn("Result") { e in ResultBadge(result: e.result) }
                .width(min: 70, ideal: 80)
            TableColumn("Took") { e in
                Text(e.secs.map { "\($0)s" } ?? "").monospacedDigit()
            }
            .width(min: 40, ideal: 50)
            TableColumn("Detail") { e in
                Text(detail(e)).lineLimit(1).help(detail(e)).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ e: BrokerEvent) -> String {
        var parts: [String] = []
        if let exit = e.exit, exit != 0 { parts.append("exit \(exit)") }
        if let reason = e.reason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    // MARK: Connections (served by the app)

    private var filteredConnections: [BrokerConnection] {
        model.connections.reversed().filter { c in
            (sandbox == "All" || c.sandbox == sandbox)
                && (broker == "All" || c.kind.rawValue == broker)
                && (!problemsOnly || isProblem(c))
        }
    }

    private var connectionsTable: some View {
        Table(filteredConnections) {
            TableColumn("Started") { c in
                Text(c.started.formatted(date: .omitted, time: .standard)).monospacedDigit()
            }
            .width(min: 90, ideal: 100)
            TableColumn("Sandbox") { c in Text(c.sandbox ?? "uid \(c.uid.map(String.init) ?? "?")") }
            TableColumn("Broker") { c in Label(c.kind.rawValue, systemImage: c.kind.symbol) }
            TableColumn("Outcome") { c in Text(outcome(c)).help(outcome(c)) }
            TableColumn("Took") { c in
                Text(c.ended.map { "\(Int($0.timeIntervalSince(c.started)))s" } ?? "…").monospacedDigit()
            }
            .width(min: 40, ideal: 50)
        }
        .overlay {
            if model.connections.isEmpty {
                Text(model.isListening
                     ? "No sandbox has used the app's sockets yet."
                     : "Brokers are off. Turn on “Run brokers” in the menu.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isProblem(_ c: BrokerConnection) -> Bool {
        switch c.outcome {
        case .rejected: return true
        case .finished(_, let status): return status != 0
        case .running: return false
        }
    }

    private func outcome(_ c: BrokerConnection) -> String {
        switch c.outcome {
        case .running(let pid): return "running (pid \(pid))"
        case .finished(_, let status):
            // Raw wait status: exit code in the high byte, signal in the low bits.
            if status & 0x7f == 0 { return "exited \((status >> 8) & 0xff)" }
            return "killed by signal \(status & 0x7f)"
        case .rejected(let why): return "rejected: \(why)"
        }
    }
}
