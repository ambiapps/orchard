import AppKit
import SwiftUI

@main
struct OrchardApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("Orchard", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Pipeline") { store.addPipeline() }
                    .keyboardShortcut("n")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            Image(systemName: store.anyBusy ? "arrow.triangle.2.circlepath" : "leaf")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than a bundled .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Keep polling from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuBarContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.pipelines.isEmpty {
            Text("No pipelines")
        }
        ForEach(store.pipelines) { runner in
            @Bindable var runner = runner
            Toggle(isOn: $runner.config.isEnabled) {
                Text(runner.config.name)
                Text(runner.status.label)
            }
            .disabled(runner.config.missingSetup != nil)
        }
        Divider()
        Button("Open Orchard…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit Orchard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
