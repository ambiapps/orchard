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
                    ForEach(store.pairingRequests) { request in
                        PairingRequestRow(request: request)
                    }
                    ForEach(store.approvedClients) { client in
                        LabeledContent {
                            Button("Remove") { store.removeClient(client) }
                        } label: {
                            Text(client.name)
                            Text("Approved \(client.approvedAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                }
            } header: {
                Text("Builder")
            } footer: {
                footer("""
                    Makes this Mac a builder: every build from now on is also kept for other Macs running \
                    Orchard, which install it on their own devices without Xcode or the source code. Give \
                    them the link. If they aren't on this network, replace the host name with one they can \
                    reach, such as this Mac's VPN or Tailscale name. A Mac that adds the link shows a code; \
                    it gets builds only after you enter that code here.
                    """)
            }

            Section {
                TextField("Builder link", text: $store.builderLink, prompt: Text("http://office-mac.local:8642"))
                    .autocorrectionDisabled()
                if case .awaitingApproval(let code) = store.builderStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Waiting for the builder to approve this Mac", systemImage: "hourglass")
                            .font(.callout)
                        Text(ClientIdentity.format(code))
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Enter this code in Orchard's Settings on the builder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let status = builderStatus {
                    HStack {
                        Label(status.text, systemImage: status.symbol)
                            .foregroundStyle(status.color)
                            .font(.callout)
                        if store.builderStatus == .declined {
                            Spacer()
                            Button("Ask Again") { store.requestApprovalAgain() }
                        }
                    }
                }
            } header: {
                Text("Client")
            } footer: {
                footer("""
                    Paste the link from a builder to install its builds on the devices connected to this Mac. \
                    Someone at the builder approves this Mac with the code it shows. Then its pipelines show \
                    up in the main window: choose your devices there and enable them.
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
        case .awaitingApproval: nil
        case .declined: ("The builder declined this Mac.", "xmark.circle", .orange)
        case .failed(let reason): (reason, "exclamationmark.triangle", .orange)
        }
    }
}

/// A Mac asking for this builder's builds: approving it takes the code it shows.
private struct PairingRequestRow: View {
    @Environment(AppStore.self) private var store
    let request: PairingRequest
    @State private var code = ""
    @State private var wrongCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name)
                Text(["Wants to download builds", request.address].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Code", text: $code, prompt: Text("Code on that Mac"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 150)
                    .onSubmit(approve)
                    .onChange(of: code) { wrongCode = false }
                Spacer()
                Button("Decline") { store.decline(request) }
                Button("Approve", action: approve)
                    .disabled(code.filter { $0.isASCII && $0.isNumber }.count != 6)
            }
            if wrongCode {
                Text("That isn't the code \(request.name) shows.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func approve() {
        wrongCode = !store.approve(request, code: code)
    }
}
