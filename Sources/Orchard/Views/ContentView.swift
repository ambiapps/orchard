import SwiftUI

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
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
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
        } detail: {
            if let runner = store.pipelines.first(where: { $0.id == selection }) {
                PipelineDetailView(runner: runner)
                    .id(runner.id)
            } else {
                ContentUnavailableView("Select a Pipeline", systemImage: "sidebar.left")
            }
        }
        .onAppear {
            if selection == nil { selection = store.pipelines.first?.id }
        }
        .onDeleteCommand {
            if let runner = store.pipelines.first(where: { $0.id == selection }) { delete(runner) }
        }
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
