import Foundation
import Testing
@testable import Orchard

struct GitTests {
    @Test func readsBranchesAndHeadsFromRemote() async throws {
        let origin = try TemporaryDirectory()
        try await git(["init", "--bare", "--initial-branch=main"], in: origin.url)

        let clone = try TemporaryDirectory()
        try await git(["clone", origin.url.path, "."], in: clone.url)
        let main = try await commit("First", in: clone.url)
        try await git(["push", "origin", "HEAD:main"], in: clone.url)
        let feature = try await commit("Second", in: clone.url)
        try await git(["push", "origin", "HEAD:refs/heads/feature/x"], in: clone.url)

        #expect(await Git.remote(in: clone.url) == "origin")
        #expect(try await Git.branches(in: clone.url) == ["feature/x", "main"])
        #expect(try await Git.headCommit(of: "main", in: clone.url) == main)
        #expect(try await Git.headCommit(of: "feature/x", in: clone.url) == feature)
        #expect(await Git.subject(of: feature, in: clone.url) == "Second")
        await #expect(throws: GitError.self) {
            try await Git.headCommit(of: "missing", in: clone.url)
        }
    }

    @Test func fallsBackToLocalBranchesWithoutRemote() async throws {
        let repo = try TemporaryDirectory()
        try await git(["init", "--initial-branch=main"], in: repo.url)
        let head = try await commit("Only", in: repo.url)
        try await git(["branch", "topic"], in: repo.url)

        #expect(await Git.remote(in: repo.url) == nil)
        #expect(await Git.isRepository(repo.url))
        #expect(try await Git.branches(in: repo.url) == ["main", "topic"])
        #expect(try await Git.headCommit(of: "topic", in: repo.url) == head)
    }

    @Test func preparesAndReusesWorktree() async throws {
        let repo = try TemporaryDirectory()
        try await git(["init", "--initial-branch=main"], in: repo.url)
        let first = try await commit("First", in: repo.url)
        let second = try await commit("Second", in: repo.url)

        let scratch = try TemporaryDirectory()
        let worktree = scratch.url.appendingPathComponent("pipeline/checkout")
        try await Git.prepareWorktree(at: worktree, repo: repo.url, branch: "main", commit: first) { _ in }
        #expect(try await git(["rev-parse", "HEAD"], in: worktree) == first)

        try "junk".write(to: worktree.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try await Git.prepareWorktree(at: worktree, repo: repo.url, branch: "main", commit: second) { _ in }
        #expect(try await git(["rev-parse", "HEAD"], in: worktree) == second)
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("untracked.txt").path))

        await Git.removeWorktree(at: worktree, repo: repo.url)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let identity = ["-c", "user.name=Orchard Tests", "-c", "user.email=tests@example.com",
                        "-c", "commit.gpgsign=false"]
        return try await Shell.git(identity + arguments, in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, in repo: URL) async throws -> String {
        try await git(["commit", "--allow-empty", "-m", message], in: repo)
        return try await git(["rev-parse", "HEAD"], in: repo)
    }
}
