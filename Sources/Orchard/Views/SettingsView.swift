import SwiftUI

/// The app-wide settings window (Orchard → Settings…).
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Set up connected devices automatically", isOn: $store.setsUpDevicesAutomatically)
            } footer: {
                Text("""
                    For a headless Mac that nobody looks at. Plug a device in with a cable, unlock it and tap \
                    Trust: Orchard pairs it, prepares it for development and adds it to the pipelines that \
                    deploy to new devices. After that you can unplug it, and it gets deploys over Wi-Fi while \
                    it's on this Mac's network. If Developer Mode is off, the device asks you to turn it on.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
