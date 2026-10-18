import SwiftUI

/// Column widths of the main window's three-column split view: pipelines, settings, activity.
enum Layout {
    static let sidebarMin: CGFloat = 200
    static let sidebarIdeal: CGFloat = 240
    static let sidebarMax: CGFloat = 360
    static let settingsMin: CGFloat = 340
    static let settingsIdeal: CGFloat = 440
    static let activityMin: CGFloat = 360
    static let activityIdeal: CGFloat = 480

    /// Fits every column at its minimum width, plus room for the dividers.
    static let windowMinWidth = sidebarMin + settingsMin + activityMin + 20
    static let windowMinHeight: CGFloat = 600
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.pipelines) { runner in
                    PipelineRow(runner: runner)
                        .tag(runner.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(runner) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: Layout.sidebarMin, ideal: Layout.sidebarIdeal, max: Layout.sidebarMax)
            .toolbar {
                ToolbarItem {
                    Button("New Pipeline", systemImage: "plus") {
                        selection = store.addPipeline().id
                    }
                }
            }
            .overlay {
                if store.pipelines.isEmpty {
                    ContentUnavailableView {
                        Label("No Pipelines", systemImage: "leaf")
                    } description: {
                        Text("Add a pipeline to watch a branch and deploy it to your devices.")
                    } actions: {
                        Button("New Pipeline") { selection = store.addPipeline().id }
                    }
                }
            }
        } content: {
            Group {
                if let runner = selectedRunner {
                    PipelineSettingsView(runner: runner)
                        .id(runner.id)
                } else {
                    ContentUnavailableView("Select a Pipeline", systemImage: "sidebar.left")
                }
            }
            .navigationSplitViewColumnWidth(min: Layout.settingsMin, ideal: Layout.settingsIdeal)
        } detail: {
            Group {
                if let runner = selectedRunner {
                    PipelineDetailView(runner: runner)
                        .id(runner.id)
                } else {
                    // An empty column ignores its width limits; keep a view here so it doesn't.
                    Color.clear
                }
            }
            .navigationSplitViewColumnWidth(min: Layout.activityMin, ideal: Layout.activityIdeal)
        }
        .onAppear {
            if selection == nil { selection = store.pipelines.first?.id }
        }
        .onDeleteCommand {
            if let runner = selectedRunner { delete(runner) }
        }
    }

    private var selectedRunner: PipelineRunner? {
        store.pipelines.first { $0.id == selection }
    }

    private func delete(_ runner: PipelineRunner) {
        if selection == runner.id { selection = nil }
        store.remove(runner)
    }
}

private struct PipelineRow: View {
    let runner: PipelineRunner

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(runner: runner)
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.config.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if runner.status.isBusy || runner.config.isEnabled { return runner.status.label }
        return runner.config.branch ?? "Not configured"
    }
}

struct StatusDot: View {
    let runner: PipelineRunner

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        if runner.status.isBusy { return .blue }
        if !runner.config.isEnabled { return .secondary.opacity(0.5) }
        if case .failed = runner.lastRun?.outcome { return .red }
        if runner.lastError != nil { return .orange }
        return .green
    }
}
