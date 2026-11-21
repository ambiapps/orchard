import Foundation
import Testing
@testable import Orchard

struct PullRequestTests {
    private let sha1 = String(repeating: "a", count: 40)
    private let sha2 = String(repeating: "b", count: 40)

    @Test func parsesGitHubsList() throws {
        let output = """
        A new release of gh is available: 2.80.0 → 2.81.0
        [{"number":12,"title":"New onboarding","author":{"login":"ada","name":"Ada"},"url":"https://github.com/o/r/pull/12",\
        "headRefOid":"\(sha1)","headRefName":"ada/onboarding","isDraft":true,"isCrossRepository":false,\
        "updatedAt":"2026-11-20T10:00:00Z"},
        {"number":13,"title":"Broken","headRefOid":"not-a-sha","isDraft":false,"isCrossRepository":false},
        {"number":14,"title":"From a fork","author":{"login":"eve"},"headRefOid":"\(sha2)","isCrossRepository":true}]
        """
        let pullRequests = try GitHub.parsePullRequests(output)
        #expect(pullRequests.map(\.number) == [12, 14])
        let first = try #require(pullRequests.first)
        #expect(first.title == "New onboarding")
        #expect(first.author == "ada")
        #expect(first.headCommit == sha1)
        #expect(first.headBranch == "ada/onboarding")
        #expect(first.isDraft)
        #expect(!first.isFromFork)
        #expect(first.updatedAt == ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z"))
        #expect(first.ref == "refs/pull/12/head")
        #expect(pullRequests[1].isFromFork)
        #expect(throws: GitHubError.unreadable) { try GitHub.parsePullRequests("gh: not logged in") }
    }

    @Test func buildsTheNewestPullRequestsButNoneFromForks() {
        func pullRequest(_ number: Int, hoursAgo: Double, fork: Bool = false) -> PullRequest {
            PullRequest(number: number, title: "#\(number)", headCommit: sha1, isFromFork: fork,
                        updatedAt: Date().addingTimeInterval(-hoursAgo * 3600))
        }
        let open = [pullRequest(1, hoursAgo: 5), pullRequest(2, hoursAgo: 1), pullRequest(3, hoursAgo: 0, fork: true),
                    pullRequest(4, hoursAgo: 3)]
        #expect(GitHub.selection(open).map(\.number) == [2, 4, 1])
        #expect(GitHub.selection(open, limit: 2).map(\.number) == [2, 4])
    }

    @Test func aHeadIsBuiltOnce() {
        let open = [
            PullRequest(number: 1, title: "Built", headCommit: sha1),
            PullRequest(number: 2, title: "New commit", headCommit: sha2),
            PullRequest(number: 3, title: "Failed", headCommit: sha1),
            PullRequest(number: 4, title: "New", headCommit: sha1),
        ]
        let needed = GitHub.needingBuild(open, built: [1: sha1, 2: sha1], attempted: [3: sha1])
        #expect(needed.map(\.number) == [2, 4])
    }

    @Test func findsGhOnThePath() throws {
        let bin = try TemporaryDirectory()
        try bin.write("gh", "#!/bin/sh\n")
        let gh = bin.url.appendingPathComponent("gh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        #expect(GitHub.ghPath(environment: ["PATH": "/nonexistent:\(bin.url.path)"]) == gh.path)
        #expect(GitHub.ghPath(environment: ["PATH": "/nonexistent"]) == nil)
    }

    /// A busy set of pull requests mustn't push the branch's runs out of the history.
    @Test func runsOfTheBranchAndOfPullRequestsAreKeptApart() {
        var runs: [RunRecord] = []
        for index in 0..<6 {
            var run = RunRecord(commit: sha1)
            run.pullRequest = index.isMultiple(of: 3) ? nil : index
            runs.append(run)
        }
        // Branch runs at 0 and 3; pull requests 1, 2, 4, 5.
        let kept = runs.keepingRuns(2)
        #expect(kept.map(\.pullRequest) == [nil, 1, 2, nil])
    }

    @Test func configsAndRunsSavedBeforePullRequestsDecode() throws {
        let config = try JSONDecoder().decode(PipelineConfig.self, from: Data(
            #"{"id":"8D4D0A0E-6B1E-4C3A-9B57-1A2B3C4D5E6F","name":"App","configuration":"Debug","pollInterval":60,"isEnabled":true,"devices":[]}"#.utf8))
        #expect(config.buildsPullRequests == nil)
        let run = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(RunRecord(commit: sha1)))
        #expect(run.pullRequest == nil)
    }

    /// A catalog from a builder that doesn't build pull requests (or from 1.0.21 and earlier).
    @Test func catalogsWithoutPullRequestsDecode() throws {
        let json = #"{"builder":"Office Mac","hasDeviceSupport":true,"pipelines":[{"id":"8D4D0A0E-6B1E-4C3A-9B57-1A2B3C4D5E6F","name":"App","builds":[]}]}"#
        let catalog = try JSONDecoder().decode(BuildCatalog.self, from: Data(json.utf8))
        #expect(catalog.pipelines.first?.pullRequests == nil)
    }

    @Test func checksOutAPullRequestsHead() async throws {
        let origin = try TemporaryDirectory()
        try await git(["init", "--bare", "--initial-branch=main"], in: origin.url)
        let clone = try TemporaryDirectory()
        try await git(["clone", origin.url.path, "."], in: clone.url)
        try await git(["commit", "--allow-empty", "-m", "Main"], in: clone.url)
        try await git(["push", "origin", "HEAD:main"], in: clone.url)
        try await git(["commit", "--allow-empty", "-m", "Pull request"], in: clone.url)
        let head = try await git(["rev-parse", "HEAD"], in: clone.url)
        // GitHub keeps this ref for every pull request.
        try await git(["push", "origin", "HEAD:refs/pull/7/head"], in: clone.url)
        try await git(["reset", "--hard", "HEAD~1"], in: clone.url)
        try await git(["reflog", "expire", "--expire=now", "--all"], in: clone.url)
        try await git(["gc", "--prune=now", "--quiet"], in: clone.url)

        let scratch = try TemporaryDirectory()
        let worktree = scratch.url.appendingPathComponent("PullRequestBuild/checkout")
        let pullRequest = PullRequest(number: 7, title: "Pull request", headCommit: head)
        try await Git.prepareWorktree(at: worktree, repo: clone.url, fetching: pullRequest.ref, commit: head) { _ in }
        #expect(try await git(["rev-parse", "HEAD"], in: worktree) == head)
        await Git.removeWorktree(at: worktree, repo: clone.url)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let identity = ["-c", "user.name=Orchard Tests", "-c", "user.email=tests@example.com",
                        "-c", "commit.gpgsign=false"]
        return try await Shell.git(identity + arguments, in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
