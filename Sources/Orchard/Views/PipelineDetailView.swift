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
                    Button("Build & Deploy Now", systemImage: "hammer") { runner.buildNow() }
                        .disabled(runner.config.missingSetup != nil || runner.status.isBusy)
                }
                Toggle(isOn: $runner.config.isEnabled) {
                    Label(runner.config.isEnabled ? "Enabled" : "Enable",
                          systemImage: runner.config.isEnabled ? "dot.radiowaves.left.and.right" : "power")
                }
                .toggleStyle(.button)
                .tint(runner.config.isEnabled ? .green : nil)
                .disabled(runner.config.missingSetup != nil && !runner.config.isEnabled)
                .help(runner.config.missingSetup ?? "Poll the branch and deploy every new commit")
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
            }

            DevicesSection(runner: runner)

            Section("Polling") {
                Picker("Check every", selection: $runner.config.pollInterval) {
                    ForEach([30.0, 60, 120, 300, 900], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")")
                            .tag(seconds)
                    }
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
                if let head = runner.remoteHead {
                    LabeledContent("Branch head", value: head.shortSHA).monospaced()
                }
                if let error = runner.lastError {
                    Text(error).foregroundStyle(.orange).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(runner.config.name)
        .navigationSubtitle(runner.status.label)
        .task(id: runner.config.repoPath) { await loadRepository() }
        .task(id: [runner.config.repoPath, runner.config.containerPath].compactMap { $0 }) { await loadSchemes() }
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

private struct DevicesSection: View {
    @Bindable var runner: PipelineRunner
    @Environment(AppStore.self) private var store

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
                        }
                    }
                }
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
            Text("Paired devices from Xcode and booted simulators. Devices of the same platform share one build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Discovered devices, plus selected ones that aren't currently visible.
    private var rows: [DiscoveredDevice] {
        let discovered = store.devices
        let missing = runner.config.devices
            .filter { device in !discovered.contains { $0.id == device.id } }
            .map { DiscoveredDevice(device: $0, isConnected: false) }
        return discovered + missing
    }

    private func detail(for row: DiscoveredDevice) -> String {
        var parts = [row.device.model]
        if row.device.kind == .physical {
            parts.append(row.device.platform.displayName + " " + row.device.osVersion)
            parts.append(row.isConnected ? "Connected" : "Not connected")
        }
        return parts.joined(separator: " · ")
    }

    private func binding(for device: Device) -> Binding<Bool> {
        Binding {
            runner.config.devices.contains { $0.id == device.id }
        } set: { isOn in
            runner.config.devices.removeAll { $0.id == device.id }
            if isOn { runner.config.devices.append(device) }
        }
    }
}
