import AppKit
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

            Section {
                Toggle("Share builds with other Macs", isOn: $store.sharesBuilds)
                if store.sharesBuilds {
                    LabeledContent("Link") {
                        HStack {
                            Text(store.sharingLink)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(store.sharingLink, forType: .string)
                            }
                        }
                    }
                    if let error = store.sharingError {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            } header: {
                Text("Builder")
            } footer: {
                footer("""
                    Makes this Mac a builder: every build from now on is also kept for other Macs running \
                    Orchard, which install it on their own devices without Xcode or the source code. Give \
                    them the link. If they aren't on this network, replace the host name with one they can \
                    reach, such as this Mac's VPN or Tailscale name. Anyone with the link can download the builds.
                    """)
            }

            Section {
                TextField("Builder link", text: $store.builderLink, prompt: Text("http://office-mac.local:8642/#…"))
                    .autocorrectionDisabled()
                if let status = builderStatus {
                    Label(status.text, systemImage: status.symbol)
                        .foregroundStyle(status.color)
                        .font(.callout)
                }
            } header: {
                Text("Client")
            } footer: {
                footer("""
                    Paste the link from a builder to install its builds on the devices connected to this Mac. \
                    Its pipelines show up in the main window: choose your devices there and enable them.
                    """)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var builderStatus: (text: String, symbol: String, color: Color)? {
        switch store.builderStatus {
        case .none: nil
        case .invalidLink: ("That isn't a builder link.", "exclamationmark.triangle", .orange)
        case .connecting: ("Connecting…", "ellipsis", .secondary)
        case .connected(let name, let pipelines):
            ("Connected to \(name) · \(pipelines) pipeline\(pipelines == 1 ? "" : "s")", "checkmark.circle", .green)
        case .failed(let reason): (reason, "exclamationmark.triangle", .orange)
        }
    }
}
