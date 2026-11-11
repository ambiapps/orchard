import AppKit
import SwiftUI

struct ActivityView: View {
    let runner: PipelineRunner

    var body: some View {
        VSplitView {
            RunsList(runner: runner)
                .frame(minHeight: 140, idealHeight: 220)
            LogView(runner: runner)
                .frame(minHeight: 160)
        }
    }
}

private struct RunsList: View {
    let runner: PipelineRunner
    @State private var expanded: Set<RunRecord.ID> = []

    var body: some View {
        List {
            Section("Deploys") {
                if runner.runs.isEmpty {
                    Text("No deploys yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(runner.runs) { run in
                    let isExpanded = expanded.contains(run.id)
                    RunRow(runner: runner, run: run, isExpanded: isExpanded) {
                        if isExpanded { expanded.remove(run.id) } else { expanded.insert(run.id) }
                    }
                    .listRowSeparator(isExpanded ? .hidden : .automatic, edges: .bottom)
                    // One row per commit: a List row doesn't re-measure reliably when it grows in place.
                    if isExpanded, let changes = run.changes {
                        ForEach(changes.prefix(Git.changesLimit)) { CommitRow(change: $0) }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 16)
    }
}

private struct RunRow: View {
    let runner: PipelineRunner
    let run: RunRecord
    let isExpanded: Bool
    let toggleChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                OutcomeIcon(outcome: run.outcome)
                Text(run.commit.shortSHA).monospaced()
                Text(run.subject ?? "")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                // Deploys are kept across launches, so older ones need their date.
                let started = Text(run.startedAt, format: Calendar.current.isDateInToday(run.startedAt)
                    ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
                Group {
                    if let finishedAt = run.finishedAt {
                        started + Text(" · \(finishedAt.timeIntervalSince(run.startedAt).formattedDuration)")
                    } else {
                        started
                    }
                }
                .foregroundStyle(.secondary)
                .font(.caption)
                if let logFile = run.logFile {
                    Button("Log", systemImage: "doc.text") { NSWorkspace.shared.open(logFile) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Open the full build log")
                }
            }
            HStack(spacing: 10) {
                ForEach(runner.config.devices.filter { run.deviceOutcomes[$0.id] != nil }) { device in
                    DeviceOutcomeLabel(device: device, outcome: run.deviceOutcomes[device.id] ?? .pending,
                                       canRedeploy: runner.canRedeploy(device, from: run)) {
                        runner.redeploy(device, from: run.id)
                    }
                }
                if let phases = run.timings?.phases, !phases.isEmpty {
                    Spacer()
                    Text(phases.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let changes = run.changes, !changes.isEmpty, let base = run.baseCommit {
                Button(action: toggleChanges) {
                    Label(changesLabel(changes, base: base), systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let message = run.outcome.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(run.outcome == .failed(message) ? .red : .orange)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private func changesLabel(_ changes: [CommitSummary], base: String) -> String {
        let count = changes.count > Git.changesLimit ? "\(Git.changesLimit)+" : "\(changes.count)"
        return "\(count) \(changes.count == 1 ? "commit" : "commits") since \(base.shortSHA)"
    }
}

/// A device's outcome in a deploy. A device that failed is a button that deploys the same build
/// to it again, while that build is still around.
private struct DeviceOutcomeLabel: View {
    let device: Device
    let outcome: DeployOutcome
    let canRedeploy: Bool
    let redeploy: () -> Void

    var body: some View {
        if canRedeploy {
            Button(action: redeploy) {
                Label {
                    HStack(spacing: 3) {
                        Text(device.name)
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                } icon: {
                    OutcomeIcon(outcome: outcome).imageScale(.small)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .help("\(outcome.message.map { "\($0)\n" } ?? "")Click to deploy this build to \(device.name) again")
        } else {
            Label {
                Text(device.name).font(.caption)
            } icon: {
                OutcomeIcon(outcome: outcome).imageScale(.small)
            }
            .help(outcome.message ?? device.name)
        }
    }
}

/// A commit a deploy brought in since the previously deployed commit.
private struct CommitRow: View {
    let change: CommitSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(change.sha.shortSHA).monospaced().foregroundStyle(.secondary)
            Text(change.subject).lineLimit(1)
            Text(change.author).foregroundStyle(.tertiary).lineLimit(1)
        }
        .font(.caption)
        .padding(.leading, 18)
        .help(change.subject)
        .textSelection(.enabled)
    }
}

struct OutcomeIcon: View {
    let outcome: DeployOutcome

    var body: some View {
        switch outcome {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

extension DeployOutcome {
    var message: String? {
        switch self {
        case .warning(let message), .failed(let message): message
        default: nil
        }
    }
}

private struct LogView: View {
    let runner: PipelineRunner

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Logs Folder", systemImage: "folder") {
                    let dir = Paths.logs.appendingPathComponent(runner.id.uuidString)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                Button("Clear", systemImage: "trash") { runner.clearLog() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(runner.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.date, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(.tertiary)
                                Text(line.text)
                                    .foregroundStyle(color(for: line.level))
                                    .fontWeight(line.level == .step ? .semibold : .regular)
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if let id = runner.log.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: runner.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .info: .primary
        case .step: .accentColor
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}
