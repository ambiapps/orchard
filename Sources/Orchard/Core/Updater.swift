import AppKit
import Foundation
import Observation

/// A release version: the marketing version from `VERSION` plus CI's build number, as in the
/// release tag `v1.0.6(7)` or the bundle's `CFBundleShortVersionString`/`CFBundleVersion`.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]
    let build: Int

    init(components: [Int], build: Int) {
        self.components = components
        self.build = build
    }

    /// Parses `v1.0.6(7)`, `1.0.6(7)` or `1.0.6` (build 0).
    init?(tag: String) {
        var text = Substring(tag.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        var build = 0
        if let open = text.firstIndex(of: "("), text.last == ")" {
            guard let number = Int(text[text.index(after: open)..<text.index(before: text.endIndex)]) else { return nil }
            build = number
            text = text[..<open]
        }
        self.init(marketing: String(text), build: build)
    }

    init?(marketing: String, build: Int) {
        let parts = marketing.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.init(components: parts.map { $0! }, build: build)
    }

    /// The running app's version, or nil when it isn't a bundled .app (`swift run`).
    static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
        return AppVersion(marketing: marketing, build: build)
    }

    var marketing: String { components.map(String.init).joined(separator: ".") }
    var description: String { build > 0 ? "\(marketing) (\(build))" : marketing }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return lhs.build < rhs.build
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A GitHub release, as returned by `GET /repos/{owner}/{repo}/releases/latest`.
struct Release: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var version: AppVersion? { AppVersion(tag: tagName) }
    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
}

/// Checks GitHub for a newer release, offers it in an alert and installs it in place.
///
/// Installing downloads the release DMG, copies the app out of it and hands the swap to a small
/// shell script that waits for Orchard to quit, replaces the bundle and relaunches it.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case installing
    }

    /// What a check does about a newer release.
    enum Action: Equatable {
        case none
        case prompt
        case install
    }

    /// The defaults key behind `installsAutomatically`. A Mac nobody sits at can be opted in over
    /// SSH: `defaults write se.ambi.Orchard automaticallyInstallUpdates -bool YES`.
    nonisolated static let automaticKey = "automaticallyInstallUpdates"
    /// How often to look for a release while updates install automatically.
    nonisolated static let automaticCheckInterval: Duration = .seconds(60 * 60)

    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/ambiapps/orchard/releases/latest")!

    private(set) var state: State = .idle
    /// The newer release found by the last check, if any.
    private(set) var available: Release?
    /// Opt-in for Macs nobody sits at: install new releases without asking, once no pipeline is
    /// building or deploying, and keep checking for them while running.
    private(set) var installsAutomatically: Bool {
        didSet { defaults?.set(installsAutomatically, forKey: Self.automaticKey) }
    }

    @ObservationIgnored let current: AppVersion?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let skippedKey = "skippedUpdateTag"
    /// The release an install was started for, so the next launch can tell whether it took.
    @ObservationIgnored private let pendingKey = "pendingUpdateTag"
    /// The release whose swap didn't take, so it isn't installed (and relaunched for) in a loop.
    @ObservationIgnored private let failedKey = "failedUpdateTag"
    @ObservationIgnored private var isPrompting = false
    @ObservationIgnored private var started = false
    /// Set by "Install and Relaunch" while an automatic install waits for pipelines: don't wait.
    @ObservationIgnored private var installNow = false
    /// Releases a background check already showed the window for, so the hourly checks of
    /// automatic installs that can't replace the app don't bring it back after "Later".
    @ObservationIgnored private var promptedTags: Set<String> = []
    /// Whether a pipeline is building or deploying, so the alert can warn that updating stops it.
    @ObservationIgnored var isBusy: () -> Bool = { false }

    init(current: AppVersion? = .current(), defaults: UserDefaults? = .standard) {
        self.current = current
        self.defaults = defaults
        installsAutomatically = defaults?.bool(forKey: Self.automaticKey) ?? false
    }

    /// Checks once, shortly after launch; after that only "Check for Updates…" does, unless
    /// updates install automatically: then it checks every `automaticCheckInterval`. Does
    /// nothing when not running as a bundled .app, because there's no version to compare against.
    func start() {
        guard current != nil, !started else { return }
        started = true
        reportFailedInstall()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.check(userInitiated: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.automaticCheckInterval)
                guard let self else { return }
                reloadSettings()
                if installsAutomatically { await check(userInitiated: false) }
            }
        }
    }

    /// Turns automatic installs on or off. Turning them on checks right away.
    func setInstallsAutomatically(_ on: Bool) {
        installsAutomatically = on
        if on, started { Task { await check(userInitiated: false) } }
    }

    /// Picks up a `defaults write` made while Orchard is running.
    func reloadSettings() {
        let stored = defaults?.bool(forKey: Self.automaticKey) ?? false
        if stored != installsAutomatically { installsAutomatically = stored }
    }

    /// Looks for a newer release. Background checks only speak up about a version the user
    /// hasn't skipped; a check from the menu always reports its result.
    func check(userInitiated: Bool) async {
        guard state == .idle else { return }
        state = .checking
        let result: Result<Release, Error>
        do {
            result = .success(try await Self.fetchLatest())
        } catch {
            result = .failure(error)
        }
        state = .idle

        switch result {
        case .failure(let error):
            if userInitiated { showError("Couldn't check for updates", error) }
        case .success(let release):
            guard let version = release.version, Self.isNewer(version, than: current) else {
                available = nil
                if userInitiated { showUpToDate() }
                return
            }
            available = release
            let action = Self.action(
                for: release.tagName, userInitiated: userInitiated, automatic: installsAutomatically,
                canInstall: Self.installLocation() != nil && release.dmg != nil,
                skipped: defaults?.string(forKey: skippedKey), failed: defaults?.string(forKey: failedKey))
            switch action {
            case .none: break
            case .prompt:
                if userInitiated || promptedTags.insert(release.tagName).inserted { prompt(release) }
            case .install:
                await install(release, unattended: true)
            }
        }
    }

    /// What to do about the newer release `tag`. A check from the menu always asks. A background
    /// check stays quiet about a skipped version; with automatic installs on it installs
    /// without asking, except a release whose install already failed once (`failed`): the launch
    /// after that failure reported it, and trying again would quit and relaunch Orchard in a loop.
    nonisolated static func action(for tag: String, userInitiated: Bool, automatic: Bool, canInstall: Bool,
                                   skipped: String?, failed: String?) -> Action {
        if userInitiated { return .prompt }
        if tag == skipped { return .none }
        guard automatic, canInstall else { return .prompt }
        return tag == failed ? .none : .install
    }

    /// Whether `version` should be offered over `current`. Without a current version (`swift run`)
    /// any release counts, so a manual check can still point at the download.
    /// A local `build-app.sh` build has build number 1, so it's compared by marketing version
    /// only: the release of the version you just built isn't offered as an update.
    nonisolated static func isNewer(_ version: AppVersion, than current: AppVersion?) -> Bool {
        guard let current else { return true }
        if current.build <= 1 {
            return AppVersion(components: version.components, build: 0)
                > AppVersion(components: current.components, build: 0)
        }
        return version > current
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Orchard", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered with HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Alert

    /// Shows the update alert for whatever was found last, e.g. from the menu bar item.
    func promptAvailable() {
        if let available { prompt(available) }
    }

    private func prompt(_ release: Release) {
        guard !isPrompting else { return }
        isPrompting = true
        let canInstall = Self.installLocation() != nil && release.dmg != nil
        let busy = isBusy()
        UpdateWindow.show({ choose in
            UpdateAvailableView(newVersion: release.version?.description ?? release.tagName,
                                currentVersion: self.current?.description, canInstall: canInstall,
                                busy: busy, releaseNotes: release.htmlURL, choose: choose)
        }) { [weak self] choice in
            guard let self else { return }
            isPrompting = false
            switch choice {
            case .install:
                if state == .installing {
                    installNow = true  // An automatic install is waiting for pipelines.
                } else if canInstall {
                    Task { await self.install(release) }
                } else {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            case .skip:
                defaults?.set(release.tagName, forKey: skippedKey)
            case .later:
                break
            }
        }
    }

    /// If the last launch quit to install an update but this is still an older version, the
    /// swap script couldn't replace the app (for example, macOS blocked it). Say so once.
    private func reportFailedInstall() {
        guard let version = takeFailedInstall() else { return }
        showError("Couldn't install the update",
                  UpdateError("Orchard \(version) was downloaded, but the app at \(Bundle.main.bundlePath) couldn't be replaced. Download it from GitHub instead."))
    }

    /// The version the last launch quit to install, if this launch is still older than it.
    /// Remembers its tag so automatic installs leave that release alone.
    func takeFailedInstall() -> AppVersion? {
        guard let tag = defaults?.string(forKey: pendingKey) else { return nil }
        defaults?.removeObject(forKey: pendingKey)
        guard let version = AppVersion(tag: tag), Self.isNewer(version, than: current) else { return nil }
        defaults?.set(tag, forKey: failedKey)
        return version
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Orchard \(current?.description ?? "") is the newest version."
        AlertPresenter.show(alert)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        AlertPresenter.show(alert)
    }

    // MARK: - Install

    /// The running .app, when Orchard can replace it: a bundled app whose folder is writable.
    static func installLocation(bundle: Bundle = .main) -> URL? {
        let app = bundle.bundleURL
        guard app.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
        else { return nil }
        return app
    }

    /// `unattended` is an automatic install: it waits for running pipelines instead of stopping
    /// them, and a failure is only logged, because nobody is there to dismiss an alert. The next
    /// check tries again.
    private func install(_ release: Release, unattended: Bool = false) async {
        guard state == .idle, let destination = Self.installLocation(), let dmg = release.dmg else { return }
        state = .installing
        installNow = false
        var work: URL?
        do {
            let staged = try await Self.download(dmg.browserDownloadURL, expecting: release.version)
            work = staged.deletingLastPathComponent()
            if unattended {
                if isBusy() { NSLog("Orchard: %@ is ready; waiting for pipelines to finish", release.tagName) }
                await Self.waitUntilIdle { [self] in !installNow && isBusy() }
                reloadSettings()
                // Turned off, or this version skipped, while waiting.
                let wanted = installsAutomatically && defaults?.string(forKey: skippedKey) != release.tagName
                guard installNow || wanted else {
                    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    state = .idle
                    return
                }
            }
            try Self.relaunch(replacing: destination, with: staged)
            defaults?.set(release.tagName, forKey: pendingKey)
            NSApp.terminate(nil)
        } catch {
            if let work { try? FileManager.default.removeItem(at: work) }
            state = .idle
            if unattended {
                NSLog("Orchard: couldn't install %@ automatically: %@", release.tagName, error.localizedDescription)
            } else {
                showError("Couldn't install the update", error)
            }
        }
    }

    /// Returns once `isBusy` says no pipeline is building or deploying.
    static func waitUntilIdle(_ isBusy: () -> Bool, polling interval: Duration = .seconds(15)) async {
        while isBusy() {
            try? await Task.sleep(for: interval)
        }
    }

    /// Downloads the DMG and copies the app out of it into a temporary folder, after checking
    /// it's an intact Orchard of the expected version.
    nonisolated static func download(_ url: URL, expecting version: AppVersion?) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchardUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            return try await stage(into: work, from: url, expecting: version)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private nonisolated static func stage(into work: URL, from url: URL, expecting version: AppVersion?) async throws -> URL {
        let dmg = work.appendingPathComponent("Orchard.dmg")
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed with HTTP \(http.statusCode).")
        }
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        let mount = work.appendingPathComponent("mount")
        try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                                 "-noautoopen", "-mountpoint", mount.path])
        let staged = work.appendingPathComponent("Orchard.app")
        var copyError: Error?
        do {
            try await Shell.run("/usr/bin/ditto", [mount.appendingPathComponent("Orchard.app").path, staged.path])
        } catch {
            copyError = error
        }
        // Detach before anything can delete `work`, or the image stays mounted inside it.
        if (try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path])) == nil {
            try await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }
        if let copyError { throw copyError }

        try validate(staged, expecting: version)
        try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        return staged
    }

    /// Checks that `app` is Orchard and, when known, the version the release promised.
    nonisolated static func validate(_ app: URL, expecting version: AppVersion?) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "se.ambi.Orchard"  // Set by scripts/build-app.sh.
        else { throw UpdateError("The downloaded app isn't Orchard.") }
        if let version, AppVersion.current(bundle: bundle) != version {
            throw UpdateError("The downloaded app isn't version \(version).")
        }
    }

    /// Starts a helper that waits for this process to exit, swaps `destination` for `staged`
    /// (restoring the old app if the copy fails) and opens the result. Launched with `Process`
    /// rather than `Shell` because it has to outlive Orchard.
    static func relaunch(replacing destination: URL, with staged: URL, opener: String = "/usr/bin/open",
                         waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "orchard-update",
                             String(pid),
                             destination.path, staged.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// `$1` pid to wait for, `$2` installed app, `$3` new app (inside the temporary work folder),
    /// `$4` the command that opens it (tests pass `/usr/bin/true`).
    nonisolated static let swapScript = #"""
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        work="$(dirname "$3")"
        if mv "$2" "$work/Previous.app"; then
            if /usr/bin/ditto "$3" "$2"; then
                rm -rf "$work"
            else
                # Put the old app back. If that fails, keep $work: it holds the only copy.
                rm -rf "$2"
                if [ ! -e "$2" ] && mv "$work/Previous.app" "$2"; then rm -rf "$work"; fi
            fi
        else
            # Couldn't move the app (macOS may block it); the next launch reports it.
            rm -rf "$work"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        "$4" "$2"
        """#
}

/// Shows an `NSAlert` as an ordinary panel instead of with `runModal()`, which would block the
/// main actor (and with it every pipeline) until someone answers.
@MainActor
final class AlertPresenter: NSObject {
    private static var open: Set<AlertPresenter> = []
    private let alert: NSAlert
    private let completion: (NSApplication.ModalResponse) -> Void

    private init(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    /// `display: false` wires the buttons up without putting the alert on screen (tests).
    static func show(_ alert: NSAlert, display: Bool = true,
                     completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        let presenter = AlertPresenter(alert, completion: completion)
        open.insert(presenter)
        if alert.buttons.isEmpty { alert.addButton(withTitle: "OK") }
        for button in alert.buttons {
            button.target = presenter
            button.action = #selector(clicked(_:))
        }
        guard display else { return }
        alert.layout()
        alert.window.center()
        alert.window.level = .floating
        NSApp.activate()
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func clicked(_ sender: NSButton) {
        alert.window.orderOut(nil)
        Self.open.remove(self)
        // NSAlert tags its buttons 1000, 1001, … like `alertFirstButtonReturn`.
        completion(NSApplication.ModalResponse(rawValue: sender.tag))
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
