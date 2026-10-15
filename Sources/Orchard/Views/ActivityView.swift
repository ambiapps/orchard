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

    var body: some View {
        List {
            Section("Deploys") {
                if runner.runs.isEmpty {
                    Text("No deploys yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(runner.runs) { run in
                    RunRow(run: run, devices: runner.config.devices)
                }
            }
        }
    }
}

private struct RunRow: View {
    let run: RunRecord
    let devices: [Device]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                OutcomeIcon(outcome: run.outcome)
                Text(run.commit.shortSHA).monospaced()
                Text(run.subject ?? "")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(run.startedAt, style: .time)
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
                ForEach(devices.filter { run.deviceOutcomes[$0.id] != nil }) { device in
                    let outcome = run.deviceOutcomes[device.id] ?? .pending
                    Label {
                        Text(device.name).font(.caption)
                    } icon: {
                        OutcomeIcon(outcome: outcome).imageScale(.small)
                    }
                    .help(outcome.failureMessage ?? device.name)
                }
            }
            if case .failed(let message) = run.outcome {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
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
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

extension DeployOutcome {
    var failureMessage: String? {
        if case .failed(let message) = self { message } else { nil }
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
