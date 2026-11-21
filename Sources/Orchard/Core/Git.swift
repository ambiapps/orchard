import Foundation

enum Git {
    /// `origin` if the repo has it, otherwise its first remote, otherwise nil (local-only repo).
    /// Throws when `git remote` fails, so a failure can't pass for a local-only repo and make
    /// callers read the user's possibly stale local branches instead of the remote's.
    static func remote(in repo: URL) async throws -> String? {
        let output = try await Shell.git(["remote"], in: repo)
        let remotes = output.split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    static func remoteURL(in repo: URL) async -> String? {
        guard let remote = try? await remote(in: repo) else { return nil }
        return try? await Shell.git(["remote", "get-url", remote], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isRepository(_ url: URL) async -> Bool {
        (try? await Shell.git(["rev-parse", "--show-toplevel"], in: url)) != nil
    }

    static func topLevel(of url: URL) async -> URL? {
        guard let path = try? await Shell.git(["rev-parse", "--show-toplevel"], in: url) else { return nil }
        return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Branches on the remote (or local branches for a repo without remotes).
    static func branches(in repo: URL) async throws -> [String] {
        if let remote = try await remote(in: repo) {
            let output = try await Shell.git(["ls-remote", "--heads", remote], in: repo)
            return parseRefs(output).keys.sorted()
        }
        let output = try await Shell.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
        return output.split(separator: "\n").map(String.init).sorted()
    }

    /// Current head commit of the branch, asking the remote directly so nothing local changes.
    /// Throws unless the answer is a full commit SHA.
    static func headCommit(of branch: String, in repo: URL) async throws -> String {
        if let remote = try await remote(in: repo) {
            let output = try await Shell.git(["ls-remote", "--heads", remote, "refs/heads/\(branch)"], in: repo)
            guard let sha = parseRefs(output)[branch] else {
                throw GitError.branchNotFound(branch)
            }
            return try commitSHA(sha)
        }
        return try commitSHA(try await Shell.git(["rev-parse", "refs/heads/\(branch)"], in: repo))
    }

    /// `output` trimmed, if it is a full SHA-1 or SHA-256 commit hash.
    static func commitSHA(_ output: String) throws -> String {
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [40, 64].contains(sha.count), sha.allSatisfy(\.isHexDigit) else {
            throw GitError.invalidCommit(sha)
        }
        return sha
    }

    /// Fetches `commit` and checks it out in Orchard's private worktree for this pipeline.
    /// The user's own checkout is never touched besides fetching into its object store.
    static func prepareWorktree(
        at worktree: URL, repo: URL, branch: String, commit: String,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        try await prepareWorktree(at: worktree, repo: repo, fetching: "refs/heads/\(branch)", commit: commit, log: log)
    }

    /// Fetches `ref` from the remote (say, a pull request's `refs/pull/<n>/head`) and checks
    /// `commit` out in `worktree`.
    static func prepareWorktree(
        at worktree: URL, repo: URL, fetching ref: String, commit: String,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        if let remote = try await remote(in: repo) {
            try await Shell.git(["fetch", "--no-tags", remote, ref], in: repo, onLine: log)
        }
        let fm = FileManager.default
        let isWorktree = fm.fileExists(atPath: worktree.appendingPathComponent(".git").path)
        if !isWorktree {
            try? fm.removeItem(at: worktree)
            try fm.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Shell.git(["worktree", "prune"], in: repo)
            try await Shell.git(["worktree", "add", "--detach", "--force", worktree.path, commit], in: repo, onLine: log)
        } else {
            try await Shell.git(["checkout", "--detach", "--force", commit], in: worktree, onLine: log)
            try await Shell.git(["clean", "-fd"], in: worktree, onLine: log)
        }
        if fm.fileExists(atPath: worktree.appendingPathComponent(".gitmodules").path) {
            try await Shell.git(["submodule", "update", "--init", "--recursive"], in: worktree, onLine: log)
        }
    }

    static func subject(of commit: String, in repo: URL) async -> String? {
        try? await Shell.git(["log", "-1", "--format=%s", commit], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let changesLimit = 50

    /// Commits since `base`, newest first, at most `changesLimit + 1` so callers can tell there are more.
    /// Nil unless `commit` descends from `base`: after a force-push, rollback or branch switch,
    /// `base..commit` wouldn't show what was dropped.
    static func changes(from base: String, to commit: String, in repo: URL) async -> [CommitSummary]? {
        guard (try? await Shell.git(["merge-base", "--is-ancestor", base, commit], in: repo)) != nil,
              let output = try? await Shell.git(
            ["log", "--max-count=\(changesLimit + 1)", "--format=%H%x1f%an%x1f%s", "\(base)..\(commit)"], in: repo)
        else { return nil }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return CommitSummary(sha: String(fields[0]), author: String(fields[1]), subject: String(fields[2]))
        }
    }

    static func removeWorktree(at worktree: URL, repo: URL) async {
        _ = try? await Shell.git(["worktree", "remove", "--force", worktree.path], in: repo)
        try? FileManager.default.removeItem(at: worktree)
    }

    private static func parseRefs(_ output: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            let name = parts[1].replacingOccurrences(of: "refs/heads/", with: "")
            refs[name] = String(parts[0])
        }
        return refs
    }
}

enum GitError: LocalizedError {
    case branchNotFound(String)
    case invalidCommit(String)

    var errorDescription: String? {
        switch self {
        case .branchNotFound(let branch): "Branch “\(branch)” no longer exists on the remote."
        case .invalidCommit(let output): "Git returned “\(output)” instead of a commit hash."
        }
    }
}
