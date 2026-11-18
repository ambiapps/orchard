import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                    AppStoreConnectKeyRow()
                }
            } header: {
                Text("Builder")
            } footer: {
                footer("""
                    Makes this Mac a builder: every build from now on is also kept for other Macs running \
                    Orchard, which install it on their own devices without Xcode or the source code. Give \
                    them the link. If they aren't on this network, replace the host name with one they can \
                    reach, such as this Mac's VPN or Tailscale name. A Mac that adds the link shows a code; \
                    it gets builds only after you enter that code here. With an App Store Connect API key \
                    (Admin role), approved Macs can ask this Mac to register their devices with your team; it \
                    then builds again with a new profile.
                    """)
            }

            Section {
                ForEach(store.builderLinks.indices, id: \.self) { index in
                    // A row can be asked for once more after it's removed.
                    let link = store.builderLinks.indices.contains(index) ? store.builderLinks[index] : ""
                    HStack {
                        TextField("Builder link", text: Binding(
                            get: { link },
                            set: { if store.builderLinks.indices.contains(index) { store.builderLinks[index] = $0 } }),
                                  prompt: Text("http://office-mac.local:8642"))
                            .autocorrectionDisabled()
                        if store.builderLinks.count > 1 || !link.isEmpty {
                            Button("Remove Builder", systemImage: "minus.circle") { store.removeBuilderLink(at: index) }
                                .buttonStyle(.borderless)
                                .labelStyle(.iconOnly)
                                .help("Remove this builder")
                        }
                    }
                    if case .awaitingApproval(let code) = store.builderStatus(for: link) {
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
                    } else if let status = status(of: link) {
                        HStack {
                            Label(status.text, systemImage: status.symbol)
                                .foregroundStyle(status.color)
                                .font(.callout)
                            if store.builderStatus(for: link) == .declined {
                                Spacer()
                                Button("Ask Again") { store.requestApprovalAgain() }
                            }
                        }
                    }
                }
                Button("Add Builder") { store.builderLinks.append("") }
                    .disabled(store.builderLinks.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            } header: {
                Text("Client")
            } footer: {
                footer("""
                    Paste the link from each builder to install its builds on the devices connected to this Mac. \
                    Someone at the builder approves this Mac with the code it shows. Then the builder's \
                    pipelines show up in the main window, named after it: choose your devices there and enable them.
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

    private func status(of link: String) -> (text: String, symbol: String, color: Color)? {
        switch store.builderStatus(for: link) {
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

/// The builder's App Store Connect API key, with which it registers clients' devices.
private struct AppStoreConnectKeyRow: View {
    @Environment(AppStore.self) private var store
    @State private var issuerID = ""
    @State private var keyID = ""
    @State private var privateKey: String?
    @State private var fileName: String?
    @State private var saving = false
    @State private var error: String?
    @State private var choosingFile = false

    var body: some View {
        if let key = store.appStoreConnectKey {
            LabeledContent {
                Button("Remove") { store.removeAppStoreConnectKey() }
            } label: {
                Text("App Store Connect key \(key.keyID)")
                Text("Approved Macs can ask to register their devices")
            }
        } else {
            // Separate rows, so the form lines them up with the others.
            Group {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Register devices for approved Macs")
                    Text("Add an App Store Connect API key from Users and Access → Integrations.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TextField("Issuer ID", text: $issuerID, prompt: Text("57246542-96fe-1a63-e053-…"))
                    .autocorrectionDisabled()
                TextField("Key ID", text: $keyID, prompt: Text("2X9R4HXF34"))
                    .autocorrectionDisabled()
                LabeledContent("Private key") {
                    HStack {
                        Text(fileName ?? "None")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Not NSOpenPanel.runModal(), which would hold up every pipeline while it's open.
                        Button("Choose .p8 File…") { choosingFile = true }
                            .fileImporter(isPresented: $choosingFile,
                                          allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
                                if case .success(let url) = result { read(url) }
                            }
                    }
                }
                HStack {
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Add Key", action: save)
                        .disabled(saving || privateKey == nil || issuerID.isEmpty || keyID.isEmpty)
                }
            }
        }
    }

    private func read(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Couldn't read that file."
            return
        }
        privateKey = text
        fileName = url.lastPathComponent
        error = nil
        if keyID.isEmpty, let id = AppStoreConnectKey.keyID(fromFileName: url.lastPathComponent) { keyID = id }
    }

    private func save() {
        guard let privateKey else { return }
        let key = AppStoreConnectKey(issuerID: issuerID.trimmingCharacters(in: .whitespaces),
                                     keyID: keyID.trimmingCharacters(in: .whitespaces), privateKey: privateKey)
        saving = true
        error = nil
        Task {
            do {
                try await store.setAppStoreConnectKey(key)
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
