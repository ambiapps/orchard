import AppKit
import SwiftUI

/// The detail column: run history and log, plus the pipeline's toolbar.
/// The settings form is the split view's content column (`PipelineSettingsView`), which
/// also carries the title, since the content column owns it in a three-column split. Don't nest
/// an `HSplitView` here instead: the detail column extends under the sidebar, and a nested
/// split view's minimum width grows with the sidebar until the window overflows.
struct PipelineDetailView: View {
    @Bindable var runner: PipelineRunner

    var body: some View {
        ActivityView(runner: runner)
            .toolbar {
                ToolbarItemGroup {
                    if runner.status.isBusy && runner.status != .checking {
                        Button("Cancel", systemImage: "stop.fill") { runner.cancelRun() }
                    } else {
                        Button(runner.config.isRemote ? "Install Now" : "Build & Deploy Now",
                               systemImage: runner.config.isRemote ? "arrow.down.circle" : "hammer") { runner.buildNow() }
                            .disabled(runner.missingSetup != nil || runner.status.isBusy)
                    }
                    Toggle(isOn: $runner.config.isEnabled) {
                        Label(runner.config.isEnabled ? "Enabled" : "Enable",
                              systemImage: runner.config.isEnabled ? "dot.radiowaves.left.and.right" : "power")
                    }
                    .toggleStyle(.button)
                    .tint(runner.config.isEnabled ? .green : nil)
                    .disabled(runner.missingSetup != nil && !runner.config.isEnabled)
                    .help(runner.missingSetup ?? (runner.config.isRemote
                        ? "Ask the builder for new builds and install each one"
                        : "Poll the branch and deploy every new commit"))
                }
            }
    }
}

// MARK: - Settings

struct PipelineSettingsView: View {
    @Bindable var runner: PipelineRunner
    @Environment(AppStore.self) private var store

    @State private var remoteURL: String?
    @State private var branches: [String] = []
    @State private var containers: [String] = []
    @State private var schemes: [String] = []
    @State private var loadingBranches = false
    @State private var loadingSchemes = false
    @State private var repoError: String?

    var body: some View {
        Form {
            Section("Pipeline") {
                TextField("Name", text: $runner.config.name)
            }

            if runner.config.isRemote {
                Section("Source") {
                    LabeledContent("Builder", value: runner.config.builderLabel ?? "None")
                    if let build = runner.remoteBuilds.first {
                        LabeledContent("Latest build") {
                            HStack(spacing: 4) {
                                Text(build.commit.shortSHA).monospaced()
                                Text(build.builtAt, style: .relative) + Text(" ago")
                            }
                        }
                    } else if runner.isWaitingForBuild {
                        LabeledContent("Latest build", value: "None yet")
                    }
                    if case .downloading = runner.status, let progress = runner.downloadProgress {
                        ProgressView(value: progress) { Text("Downloading") }
                    }
                }
            } else {
                localSections
            }

            DevicesSection(runner: runner)

            if store.sharesBuilds, !runner.config.isRemote {
                PullRequestsSection(runner: runner)
            }

            Section(runner.config.isRemote ? "Updates" : "Polling") {
                Picker("Check every", selection: $runner.config.pollInterval) {
                    ForEach([30.0, 60, 120, 300, 900], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")")
                            .tag(seconds)
                    }
                }
                Picker("Keep history of", selection: Binding(
                    get: { runner.config.keptRuns },
                    set: { runner.config.historyLimit = $0 })) {
                    ForEach([5, 10, 20, 50], id: \.self) { Text("Last \($0) builds").tag($0) }
                }
                if let commit = runner.config.lastDeployedCommit {
                    LabeledContent("Last deployed") {
                        HStack(spacing: 4) {
                            Text(commit.shortSHA).monospaced()
                            if let date = runner.config.lastDeployedAt {
                                Text(date, style: .relative) + Text(" ago")
                            }
                        }
                    }
                }
                if let head = runner.remoteHead, !runner.config.isRemote {
                    LabeledContent("Branch head", value: head.shortSHA).monospaced()
                }
                if let error = runner.lastError {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(runner.config.name)
        .navigationSubtitle(runner.statusLabel)
        .task(id: runner.config.repoPath) { await loadRepository() }
        .task(id: [runner.config.repoPath, runner.config.containerPath].compactMap { $0 }) { await loadSchemes() }
    }

    @ViewBuilder
    private var localSections: some View {
            Section("Source") {
                LabeledContent("Repository") {
                    HStack {
                        Text(runner.config.repoPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                            .foregroundStyle(runner.config.repoPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseRepository)
                    }
                }
                if let remoteURL {
                    LabeledContent("Remote", value: remoteURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let repoError {
                    Text(repoError).foregroundStyle(.red).font(.callout)
                }
                Picker("Branch", selection: $runner.config.branch) {
                    if runner.config.branch == nil { Text("Choose…").tag(String?.none) }
                    ForEach(options(branches, keeping: runner.config.branch), id: \.self) {
                        Text($0).tag(String?.some($0))
                    }
                }
                .disabled(runner.config.repoPath == nil)
                .overlay(alignment: .trailing) { if loadingBranches { ProgressView().controlSize(.small).padding(.trailing, 28) } }
            }

            Section("Build") {
                Picker("Project", selection: $runner.config.containerPath) {
                    if containers.isEmpty && runner.config.containerPath == nil { Text("None found").tag(String?.none) }
                    ForEach(options(containers, keeping: runner.config.containerPath), id: \.self) {
                        Text(Xcode.displayName(forContainer: $0)).tag(String?.some($0))
                    }
                }
                .disabled(runner.config.repoPath == nil)
                Picker("Scheme", selection: $runner.config.scheme) {
                    if runner.config.scheme == nil { Text("Choose…").tag(String?.none) }
                    ForEach(options(schemes, keeping: runner.config.scheme), id: \.self) {
                        Text($0).tag(String?.some($0))
                    }
                }
                .disabled(runner.config.containerPath == nil)
                .overlay(alignment: .trailing) { if loadingSchemes { ProgressView().controlSize(.small).padding(.trailing, 28) } }
                Picker("Configuration", selection: $runner.config.configuration) {
                    ForEach(options(["Debug", "Release"], keeping: runner.config.configuration), id: \.self) { Text($0) }
                }
                if store.sharesBuilds {
                    Picker("Also build for", selection: $runner.config.alsoBuilds) {
                        Text("Every platform the scheme supports").tag(BuildPlatform?.none)
                        ForEach(BuildPlatform.allCases.filter { !$0.isSimulator }, id: \.self) {
                            Text($0.displayName).tag(BuildPlatform?.some($0))
                        }
                    }
                    .help("Which platforms to build for clients, besides those of this Mac's own devices")
                }
            }
    }

    /// Keeps a stored selection visible even if it's not (yet) in the loaded list.
    private func options(_ list: [String], keeping selected: String?) -> [String] {
        guard let selected, !list.contains(selected) else { return list }
        return [selected] + list
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Repository"
        panel.message = "Choose a local clone of the git repository to deploy."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let top = await Git.topLevel(of: url) else {
                repoError = "\(url.lastPathComponent) isn't a git repository."
                return
            }
            repoError = nil
            if runner.config.repoPath != top.path {
                runner.config.repoPath = top.path
                runner.config.branch = nil
                runner.config.containerPath = nil
                runner.config.scheme = nil
                runner.config.lastDeployedCommit = nil
                runner.config.lastAttemptedCommit = nil
                if runner.config.name.hasPrefix("Pipeline ") { runner.config.name = top.lastPathComponent }
            }
        }
    }

    private func loadRepository() async {
        guard let repo = runner.config.repoURL else { return }
        remoteURL = await Git.remoteURL(in: repo)
        containers = Xcode.findContainers(in: repo)
        if runner.config.containerPath == nil { runner.config.containerPath = containers.first }

        loadingBranches = true
        defer { loadingBranches = false }
        do {
            branches = try await Git.branches(in: repo)
            repoError = nil
            if runner.config.branch == nil {
                runner.config.branch = ["main", "master", "develop"].first(where: branches.contains) ?? branches.first
            }
        } catch {
            repoError = "Couldn't list branches: \(error.localizedDescription)"
        }
    }

    private func loadSchemes() async {
        guard let repo = runner.config.repoURL, runner.config.containerPath != nil else { return }
        loadingSchemes = true
        defer { loadingSchemes = false }
        schemes = (try? await Xcode.schemes(container: runner.config.containerPath, in: repo)) ?? []
        if runner.config.scheme == nil, !schemes.isEmpty {
            let repoName = repo.lastPathComponent.lowercased()
            runner.config.scheme = schemes.first { $0.lowercased() == repoName } ?? schemes.first
        }
    }
}

// MARK: - Devices

/// Builder: whether the pipeline also builds the repository's open pull requests for clients,
/// and how each one stands.
private struct PullRequestsSection: View {
    @Bindable var runner: PipelineRunner

    var body: some View {
        Section {
            Toggle("Build pull requests", isOn: Binding(
                get: { runner.config.buildsPullRequests ?? false },
                set: { runner.config.buildsPullRequests = $0 }))
            if runner.buildsPullRequests {
                if let error = runner.pullRequestError {
                    Text(error).foregroundStyle(.orange).font(.callout)
                } else if runner.pullRequests.isEmpty {
                    Text(runner.config.isEnabled ? "No open pull requests" : "Enable the pipeline to build pull requests")
                        .foregroundStyle(.secondary)
                }
                ForEach(runner.pullRequests) { pullRequest in
                    PullRequestRow(pullRequest: pullRequest, state: state(of: pullRequest))
                }
            }
        } header: {
            Text("Pull Requests")
        } footer: {
            Text("Builds the \(GitHub.pullRequestLimit) most recently updated open pull requests for clients, after the branch. Pull requests from forks aren't built. Needs the GitHub CLI (gh), logged in on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func state(of pullRequest: PullRequest) -> PullRequestRow.State {
        if runner.currentPullRequest == pullRequest.number { return .building }
        if runner.builtPullRequests[pullRequest.number] == pullRequest.headCommit { return .built }
        if runner.attemptedPullRequests[pullRequest.number] == pullRequest.headCommit { return .failed }
        return .waiting
    }
}

private struct PullRequestRow: View {
    enum State { case waiting, building, built, failed }
    let pullRequest: PullRequest
    let state: State

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(pullRequest.number)").monospacedDigit().foregroundStyle(.secondary)
            Text(pullRequest.title).lineLimit(1).truncationMode(.tail)
            if pullRequest.isDraft {
                Text("Draft").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(pullRequest.headCommit.shortSHA).monospaced().foregroundStyle(.secondary)
            switch state {
            case .waiting:
                Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting to be built")
            case .building:
                ProgressView().controlSize(.small).help("Building")
            case .built:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Built and shared with clients")
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("The build failed; see the deploy list")
            }
        }
        .help(pullRequest.author.map { "\(pullRequest.title) by \($0)" } ?? pullRequest.title)
    }
}

private struct DevicesSection: View {
    @Bindable var runner: PipelineRunner
    @Environment(AppStore.self) private var store
    @State private var alert: RegistrationAlert?

    var body: some View {
        Section {
            ForEach(rows) { row in
                Toggle(isOn: binding(for: row.device)) {
                    HStack(spacing: 10) {
                        Image(systemName: row.device.symbolName)
                            .frame(width: 20)
                            .foregroundStyle(row.isConnected ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.device.name)
                            Text(detail(for: row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if isSelected(row.device), runner.unprovisionedDevices.contains(row.id) {
                                ProvisioningWarning(runner: runner, device: selected(row.device), alert: $alert)
                            }
                        }
                    }
                }
                // Not selectable until it's paired; automatic setup adds it when it's ready.
                .disabled(row.onboarding != nil && !isSelected(row.device))
            }
            if store.deviceSupport != .installed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Device support isn't installed", systemImage: "exclamationmark.triangle")
                        Spacer()
                        if store.deviceSupport == .installing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install…") { store.installDeviceSupport() }
                                .disabled(!store.builderHasDeviceSupport)
                        }
                    }
                    Text(deviceSupportHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.setsUpDevicesAutomatically {
                Toggle("Deploy to new devices", isOn: Binding(
                    get: { runner.config.addsNewDevices },
                    set: { runner.config.deploysToNewDevices = $0 }))
            }
        } header: {
            HStack {
                Text("Devices")
                Spacer()
                if store.isRefreshingDevices {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.refreshDevices() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
        } footer: {
            Text(store.setsUpDevicesAutomatically
                 ? "Paired devices and booted simulators. Devices of the same platform share one build. A device plugged into this Mac is set up automatically, and added here if this pipeline deploys to new devices."
                 : store.hasXcode
                    ? "Paired devices from Xcode and booted simulators. Devices of the same platform share one build."
                    : "Devices paired with this Mac. To pair one, turn on “Set up connected devices automatically” in Settings and plug it in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { alert in
            if let udid = alert.udid {
                Button("Copy UDID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(udid, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    /// The chosen device as saved, which has its UDID, rather than as discovered.
    private func selected(_ device: Device) -> Device {
        runner.config.devices.first { $0.id == device.id } ?? device
    }

    /// Discovered devices, plus selected ones that aren't currently visible: enabled ones first, then available ones.
    private var rows: [DiscoveredDevice] {
        DeviceDiscovery.listRows(discovered: store.devices, selected: runner.config.devices)
    }

    private var deviceSupportHint: String {
        if case .failed(let reason) = store.deviceSupport { return reason }
        return store.builderHasDeviceSupport
            ? "This Mac has no Xcode. Orchard can install Apple's device support (about 150 MB) from the builder instead; it asks for an administrator password."
            : "Orchard needs it to find and install on iPhones and other devices. Add a builder link in Settings to install it from the builder, or install Xcode."
    }

    private func detail(for row: DiscoveredDevice) -> String {
        var parts = [row.device.model]
        if row.device.kind == .physical {
            if !row.device.osVersion.isEmpty {
                parts.append(row.device.platform.displayName + " " + row.device.osVersion)
            }
            parts.append(row.onboarding?.label ?? (row.isConnected ? "Connected" : "Not connected"))
        }
        return parts.joined(separator: " · ")
    }

    private func isSelected(_ device: Device) -> Bool {
        runner.config.devices.contains { $0.id == device.id }
    }

    private func binding(for device: Device) -> Binding<Bool> {
        Binding {
            isSelected(device)
        } set: { isOn in
            // Enabled devices sort first, so toggling moves the row; animate the move.
            withAnimation {
                runner.config.devices.removeAll { $0.id == device.id }
                if isOn { runner.config.devices.append(device) }
            }
        }
    }
}

/// Why a request to register a device came to nothing.
struct RegistrationAlert: Equatable {
    var title: String
    var message: String
    /// Offered for copying when someone has to register the device by hand.
    var udid: String?

    /// Nil when the builder registered the device; the row says so instead.
    static func from(_ result: DeviceRegistrationResult, device: Device, builder: String) -> RegistrationAlert? {
        switch result.status {
        case .registered, .alreadyRegistered: return nil
        case .unavailable:
            return RegistrationAlert(
                title: "\(builder) can't register devices",
                message: (result.message.map { $0 + " " } ?? "It has no App Store Connect API key. ")
                    + "Ask someone there to add one in Orchard's Settings, or to register \(device.name) in the "
                    + "Apple Developer account and build again."
                    + (device.udid.map { " Its UDID is \($0)." } ?? ""),
                udid: device.udid)
        case .failed:
            return RegistrationAlert(title: "Couldn't register \(device.name)",
                                     message: result.message ?? "The builder didn't say why.", udid: device.udid)
        }
    }
}

/// Under a chosen device that the latest build's profile doesn't list. On a client pipeline,
/// with a button that asks the builder to register the device.
private struct ProvisioningWarning: View {
    let runner: PipelineRunner
    let device: Device
    @Binding var alert: RegistrationAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Not in the latest build's provisioning profile", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(runner.config.isRemote
                      ? "Installing will fail. The builder has to register the device with its team and build again."
                      : "Installing will fail. Register the device's UDID in the developer account, then build again.")
            if runner.config.isRemote {
                switch runner.registrationRequests[device.id] {
                case .requesting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Asking the builder…").font(.caption).foregroundStyle(.secondary)
                    }
                case .requested:
                    Label("Registered; waiting for the builder's new build", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case nil:
                    Button("Request to Be Added") {
                        Task {
                            let result = await runner.requestRegistration(of: device)
                            alert = .from(result, device: device, builder: runner.config.builderLabel ?? "The builder")
                        }
                    }
                    .controlSize(.small)
                    .help("Asks the builder to register this device with its team and build again")
                }
            }
        }
    }
}
