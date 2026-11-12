import Foundation
import Testing
@testable import Orchard

@MainActor
struct PipelineHistoryTests {
    @Test func keepsTheLogAcrossLaunches() throws {
        let dir = try TemporaryDirectory()
        var config = PipelineConfig()
        config.branch = "main"

        let runner = PipelineRunner(config: config, history: PipelineHistory(directory: dir.url))
        runner.config.isEnabled = true
        runner.config.isEnabled = false
        #expect(runner.log.count == 2)

        let relaunched = PipelineRunner(config: config, history: PipelineHistory(directory: dir.url))
        #expect(relaunched.log.map(\.text) == runner.log.map(\.text))
        #expect(relaunched.log.map(\.date) == runner.log.map(\.date))

        relaunched.clearLog()
        #expect(PipelineRunner(config: config, history: PipelineHistory(directory: dir.url)).log.isEmpty)
    }

    @Test func keepsDeploysAcrossLaunches() throws {
        let dir = try TemporaryDirectory()
        let config = PipelineConfig()
        var done = RunRecord(commit: String(repeating: "a", count: 40), subject: "Fix crash")
        done.changes = [CommitSummary(sha: done.commit, author: "Ada", subject: "Fix crash")]
        done.outcome = .warning("Installed, but failed to launch on iPhone")
        done.deviceOutcomes = ["phone": .warning("the device was locked")]
        done.timings = RunTimings(checkout: 3, build: 250, deploy: 39)
        done.finishedAt = done.startedAt.addingTimeInterval(292)
        var unfinished = RunRecord(commit: String(repeating: "b", count: 40))
        unfinished.deviceOutcomes = ["phone": .succeeded, "pad": .running, "mac": .pending]

        let runner = PipelineRunner(config: config, history: PipelineHistory(directory: dir.url))
        runner.runs = [unfinished, done]

        let relaunched = PipelineRunner(config: config, history: PipelineHistory(directory: dir.url))
        #expect(relaunched.runs.count == 2)
        #expect(relaunched.runs[1].id == done.id)
        #expect(relaunched.runs[1].changes == done.changes)
        #expect(relaunched.runs[1].outcome == done.outcome)
        #expect(relaunched.runs[1].timings == done.timings)
        // A deploy that was still going when Orchard quit doesn't spin forever.
        #expect(relaunched.runs[0].outcome == .failed("Interrupted"))
        #expect(relaunched.runs[0].deviceOutcomes
            == ["phone": .succeeded, "pad": .failed("Interrupted"), "mac": .failed("Interrupted")])
    }

    @Test func keepsDeploysItCannotRead() throws {
        let dir = try TemporaryDirectory()
        let unreadable = #"[{"from":"a future version"}]"#
        try dir.write("runs.json", unreadable)
        let runner = PipelineRunner(config: PipelineConfig(), history: PipelineHistory(directory: dir.url))
        #expect(runner.runs.isEmpty)
        // The next deploy saves a new list, but the unreadable one is kept aside.
        runner.runs = [RunRecord(commit: String(repeating: "a", count: 40))]
        #expect(PipelineRunner(config: PipelineConfig(), history: PipelineHistory(directory: dir.url)).runs.count == 1)
        #expect(try String(contentsOf: dir.url.appendingPathComponent("runs-unreadable.json"), encoding: .utf8)
            == unreadable)
    }

    @Test func loweringTheLimitTrimsRightAway() throws {
        let dir = try TemporaryDirectory()
        let runner = PipelineRunner(config: PipelineConfig(), history: PipelineHistory(directory: dir.url))
        runner.runs = (0..<5).map { _ in RunRecord(commit: String(repeating: "a", count: 40)) }
        runner.config.historyLimit = 2
        #expect(runner.runs.count == 2)
        #expect(PipelineRunner(config: runner.config, history: PipelineHistory(directory: dir.url)).runs.count == 2)
    }

    @Test func keepsOnlyTheNewestLogLines() throws {
        let dir = try TemporaryDirectory()
        let history = PipelineHistory(directory: dir.url, logLimit: 3)
        for i in 1...7 { history.appendLog(LogLine(level: .info, text: "\(i)")) }

        let reloaded = PipelineHistory(directory: dir.url, logLimit: 3)
        #expect(reloaded.loadLog().map(\.text) == ["5", "6", "7"])
        reloaded.flush()
        // Loading trimmed the file itself, not just what it returned.
        let fileLines = try String(contentsOf: dir.url.appendingPathComponent("activity.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(fileLines.count == 3)
    }

    @Test func trimsTheLogFileByWholeRuns() throws {
        let dir = try TemporaryDirectory()
        let history = PipelineHistory(directory: dir.url, logLimit: 4)
        for run in 1...3 {
            history.appendLog(LogLine(level: .step, text: "run \(run)", startsRun: true))
            history.appendLog(LogLine(level: .info, text: "built \(run)"))
            history.appendLog(LogLine(level: .info, text: "deployed \(run)"))
        }
        // The newest 4 lines start mid-run 2, so only run 3 is kept.
        #expect(PipelineHistory(directory: dir.url, logLimit: 4).loadLog().map(\.text)
            == ["run 3", "built 3", "deployed 3"])
    }

    @Test func formatsDurations() {
        #expect(TimeInterval(0.4).formattedDuration == "0s")
        #expect(TimeInterval(59.6).formattedDuration == "1m 0s")
        #expect(TimeInterval(250).formattedDuration == "4m 10s")
        #expect(TimeInterval(3900).formattedDuration == "1h 5m")
        #expect(RunTimings(checkout: 3, build: 250, deploy: 39).summary(total: 292)
            == "4m 52s (checkout 3s, build 4m 10s, deploy 39s)")
        #expect(RunTimings(checkout: 2).summary(total: 2) == "2s (checkout 2s)")
    }
}

struct HistoryLimitTests {
    private func line(_ text: String, startsRun: Bool = false) -> LogLine {
        LogLine(level: .info, text: text, startsRun: startsRun ? true : nil)
    }

    @Test func keepsWholeRecentRuns() {
        let log = [line("Enabled"), line("run 1", startsRun: true), line("built 1"),
                   line("run 2", startsRun: true), line("built 2"), line("Disabled")]
        #expect(log.keepingRuns(1).map(\.text) == ["run 2", "built 2", "Disabled"])
        #expect(log.keepingRuns(2).map(\.text) == log.map(\.text))
        #expect(log.keepingRuns(5).map(\.text) == log.map(\.text))
        #expect(log.keepingRuns(0).isEmpty)
    }

    @Test func capsLinesAtARunBoundary() {
        let log = [line("run 1", startsRun: true), line("built 1"), line("run 2", startsRun: true), line("built 2")]
        #expect(log.keepingLines(4).map(\.text) == log.map(\.text))
        #expect(log.keepingLines(3).map(\.text) == ["run 2", "built 2"])
        // One run longer than the cap is cut as before.
        #expect(log.keepingLines(1).map(\.text) == ["built 2"])
    }

    @Test func defaultsToTwentyBuildsForOlderConfigs() throws {
        let old = #"{"id":"8D4D0A0E-6B1E-4C3A-9B57-1A2B3C4D5E6F","name":"App","configuration":"Debug","devices":[],"pollInterval":60,"isEnabled":false}"#
        let config = try JSONDecoder().decode(PipelineConfig.self, from: Data(old.utf8))
        #expect(config.historyLimit == nil)
        #expect(config.keptRuns == 5)
        var zero = config
        zero.historyLimit = 0
        #expect(zero.keptRuns == 1)
    }
}
