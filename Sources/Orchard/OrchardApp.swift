import AppKit
import SwiftUI

@main
struct OrchardApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store: AppStore
    @State private var updater: Updater

    init() {
        let store = AppStore()
        let updater = Updater()
        updater.isBusy = { [store] in store.anyBusy }
        updater.start()
        _store = State(initialValue: store)
        _updater = State(initialValue: updater)
    }

    var body: some Scene {
        Window("Orchard", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state != .idle)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Pipeline") { store.addPipeline() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
                .environment(updater)
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
    @Environment(Updater.self) private var updater
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
        if let release = updater.available {
            Button("Update to \(release.version?.description ?? release.tagName)…") {
                updater.promptAvailable()
            }
        } else {
            Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                .disabled(updater.state != .idle)
        }
        Button("Open Orchard…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit Orchard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
