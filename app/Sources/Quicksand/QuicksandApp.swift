import AppKit
import QuicksandCore
import SwiftUI

@main
struct QuicksandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            StatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Quicksand Activity", id: "activity") {
            ActivityView()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 520)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A status-bar app: no Dock icon, even when run as a bare binary.
        NSApp.setActivationPolicy(.accessory)
        // A client that hangs up early must not kill the app on write.
        signal(SIGPIPE, SIG_IGN)
    }
}

/// The status-bar icon: an hourglass, the number of active sandboxes, and a
/// warning shape when something needs a look.
struct StatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.needsAttention ? "exclamationmark.triangle" : "hourglass")
            if model.activeCount > 0 {
                Text("\(model.activeCount)")
                    .monospacedDigit()
            }
        }
    }
}
