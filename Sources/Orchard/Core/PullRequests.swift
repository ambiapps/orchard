import Foundation

/// An open pull request on GitHub, as `gh pr list` describes it.
struct PullRequest: Codable, Hashable, Sendable, Identifiable {
    var number: Int
    var title: String
    var author: String?
    var url: String?
    /// The commit the pull request's branch points at.
    var headCommit: String
    var headBranch: String?
    var isDraft = false
    /// Opened from a fork. Its build scripts would run on the builder, so it isn't built.
    var isFromFork = false
    var updatedAt: Date?

    var id: Int { number }

    /// What `git fetch` asks the remote for. GitHub keeps it for every pull request, forks too.
    var ref: String { "refs/pull/\(number)/head" }
}

enum GitHub {
    /// How many open pull requests a builder builds: the most recently updated ones.
    static let pullRequestLimit = 10

    private static let fields = "number,title,author,url,headRefOid,headRefName,isDraft,isCrossRepository,updatedAt"

    /// The repository's open pull requests, through the GitHub CLI, which knows the repository
    /// from the clone's remote and has the user's login.
    static func openPullRequests(in repo: URL) async throws -> [PullRequest] {
        guard let gh = ghPath() else { throw GitHubError.ghMissing }
        let output: String
        do {
            output = try await Shell.run(
                gh, ["pr", "list", "--state", "open", "--limit", "100", "--json", fields], in: repo)
        } catch let error as ShellError {
            throw GitHubError.failed(error.output)
        }
        return try parsePullRequests(output)
    }

    /// `gh pr list --json` output. Lines before the JSON (a notice on stderr, which `Shell`
    /// merges) are skipped. Pull requests whose head isn't a full commit hash are left out.
    static func parsePullRequests(_ output: String) throws -> [PullRequest] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.first == "[" }),
              let data = lines[start...].joined(separator: "\n").data(using: .utf8)
        else { throw GitHubError.unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let listed: [Listed]
        do {
            listed = try decoder.decode([Listed].self, from: data)
        } catch {
            throw GitHubError.unreadable
        }
        return listed.compactMap { item in
            guard let sha = try? Git.commitSHA(item.headRefOid) else { return nil }
            return PullRequest(
                number: item.number, title: item.title, author: item.author?.login, url: item.url,
                headCommit: sha, headBranch: item.headRefName, isDraft: item.isDraft ?? false,
                isFromFork: item.isCrossRepository ?? false, updatedAt: item.updatedAt)
        }
    }

    /// The pull requests a builder builds: none from forks, the most recently updated first,
    /// at most `limit`.
    static func selection(_ pullRequests: [PullRequest], limit: Int = pullRequestLimit) -> [PullRequest] {
        Array(pullRequests
            .filter { !$0.isFromFork }
            .sorted { ($0.updatedAt ?? .distantPast, $0.number) > ($1.updatedAt ?? .distantPast, $1.number) }
            .prefix(limit))
    }

    /// The pull requests among `open` that need a build: their head isn't the one that was
    /// built (`built`, by number) or the one that was last tried and failed (`attempted`).
    static func needingBuild(_ open: [PullRequest], built: [Int: String], attempted: [Int: String]) -> [PullRequest] {
        open.filter { built[$0.number] != $0.headCommit && attempted[$0.number] != $0.headCommit }
    }

    /// `gh` on the login shell's PATH (Homebrew puts it in /opt/homebrew/bin).
    static func ghPath(environment: [String: String] = Shell.environment) -> String? {
        let fm = FileManager.default
        return (environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("gh").path }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    private struct Listed: Decodable {
        struct Author: Decodable { var login: String? }
        var number: Int
        var title: String
        var author: Author?
        var url: String?
        var headRefOid: String
        var headRefName: String?
        var isDraft: Bool?
        var isCrossRepository: Bool?
        var updatedAt: Date?
    }
}

enum GitHubError: LocalizedError, Equatable {
    case ghMissing
    case failed(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .ghMissing:
            "Building pull requests needs the GitHub CLI. Install it (brew install gh) and log in with gh auth login."
        case .failed(let output):
            "gh couldn't list the pull requests: "
                + (output.split(separator: "\n").last { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? "it failed")
        case .unreadable:
            "gh's list of pull requests couldn't be read."
        }
    }
}
