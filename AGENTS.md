# AGENTS.md

Guide for AI coding agents working on this repo. All of the code here is written by agents, so keep this file accurate: if you change something it describes, update it in the same PR.

## What Orchard is

A macOS menu bar + window app (SwiftUI, macOS 15+) for iOS/macOS developers. You point it at a local git clone, a branch, an Xcode scheme and a set of devices. While a pipeline is enabled, Orchard polls the branch and, whenever its head commit changes, builds the app and installs + launches it on every chosen device: this Mac, paired physical iPhones/iPads/Apple TVs/Apple Watches/Vision Pros, and booted simulators. It's like a tiny local CD server for your own devices.

It shells out to the developer's own tools: `git`, `xcodebuild`, `xcrun devicectl` (physical devices) and `xcrun simctl` (simulators). Its network code is `Updater`, which asks the GitHub API for the latest release and downloads its DMG, and the opt-in builder/client pair (`BuildServer`, `BuilderClient`), with which one Mac serves its builds to others.

## Layout

```
Package.swift                 SwiftPM package: executable target Orchard + test target OrchardTests
Sources/Orchard/
  OrchardApp.swift            @main: main window, menu bar extra, AppDelegate (keeps running after window closes)
  Core/
    Models.swift              BuildPlatform, Device, PipelineConfig (persisted), RunRecord, LogLine
    AppStore.swift            @Observable root state: list of PipelineRunners, discovered devices, persistence
    PipelineRunner.swift      One pipeline: poll loop, run (checkout → build per platform → deploy per device),
                              status, log, run history. Also Paths, LogFile, PipelineHistory, Notifier
    Git.swift                 Remote/branch queries via ls-remote, private worktree checkout
    Xcode.swift               Finds .xcworkspace/.xcodeproj/Package.swift, lists schemes, builds, locates the .app
    Deployer.swift            Install + launch on this Mac / physical device / simulator
    DeviceDiscovery.swift     Physical devices (devicectl JSON, paired or not) and booted simulators (simctl JSON)
    DeviceOnboarding.swift    Automatic setup of devices plugged into a headless Mac: OnboardingState, the
                              step function, the devicectl commands, DeviceLog (devices.log)
    Provisioning.swift        Reads the provisioning profiles embedded in a built app, checks them for the
                              chosen devices' UDIDs, and deletes Xcode's cached managed profiles
    Sharing.swift             Builder/client: SharedBuild, BuilderLink, SharedBuilds (the zips a builder keeps),
                              BuilderClient (catalog + downloads), BuilderError
    BuildServer.swift         The builder's HTTP server (Network.framework): HTTPRequest parsing, BuildService
                              (routing + token check), BuildServer (listener, file streaming)
    DeviceSupport.swift       Where devicectl comes from (Xcode, or the standalone copy on a client without
                              Xcode), the package a builder hands out, installing it; Shell.devicectl
    Shell.swift               Async Process wrapper with login-shell PATH and line streaming. All commands go through it
    Updater.swift             AppVersion (tag/bundle parsing, comparison), GitHub latest-release check, the
                              "Update Available" NSAlert, self-update (download DMG → stage app → swap script)
                              and the opt-in to install updates automatically
  Views/
    ContentView.swift         Three-column NavigationSplitView (pipelines | settings | activity), Layout widths
    PipelineDetailView.swift  Settings column (repo, branch, container, scheme, configuration, devices, interval)
                              and the detail column's toolbar
    ActivityView.swift        Run history and live log
    UpdateAvailableView.swift The "Update Available" window (SwiftUI in a small non-modal NSWindow)
    SettingsView.swift        The Settings window: "Set up connected devices automatically", Builder, Client
Tests/OrchardTests/           Swift Testing (`import Testing`, `@Test`, `#expect`) unit tests
Resources/AppIcon.icon/       Liquid Glass app icon (Icon Composer document: icon.json + SVG layers)
VERSION                       Marketing version (CFBundleShortVersionString); every PR bumps its patch digit
scripts/build-app.sh          Builds build/Orchard.app (release, ad-hoc signed, icon compiled with actool);
                              --install copies to ~/Applications. BUILD_NUMBER env sets CFBundleVersion (default 1)
scripts/build-dmg.sh          Builds the app and packages build/Orchard-<version>-<build>.dmg
docs/                         README screenshots (light/dark), app-icon/ previews
.github/workflows/ci.yml      CI: `swift test` + `scripts/build-app.sh` on macos-26
.github/workflows/release.yml On every push to main: test, build the DMG, publish a GitHub release
                              tagged v<VERSION>(<run number>), e.g. v1.0.0(42), with the DMG attached
```

## How a run works

1. `PipelineRunner` polls `Git.headCommit` (an `ls-remote`, so the user's checkout isn't touched) every `pollInterval` seconds (minimum 10).
2. If the head isn't `lastDeployedCommit` or `lastAttemptedCommit`, it runs. A failed commit isn't retried until a new commit lands or the user hits Build & Deploy Now.
3. It checks the commit out into Orchard's own detached worktree at `~/Library/Application Support/Orchard/Pipelines/<id>/checkout`, never in the user's clone.
4. It runs one `xcodebuild build` per `BuildPlatform` among the chosen devices (generic destination, so all iPhones share one build), with `DEBUG_INFORMATION_FORMAT=dwarf` (no dSYMs). It takes the one `.app` in the default products folder that this build signed (`Xcode.builtApp`; leftovers from earlier schemes aren't re-signed), and reads `-showBuildSettings -json` only when there isn't exactly one, because that reloads the workspace and takes up to a minute on big projects.
5. For a device platform it checks every `embedded.mobileprovision` in the app (its own, each extension's and app clip's; not an embedded watch app's) for each chosen device's hardware UDID (`Provisioning.devicesMissing`). The generic destination gives `-allowProvisioningUpdates` no reason to refresh a cached Xcode-managed profile that predates a device, and installing would fail with `ApplicationVerificationFailed` (0xE8008012). If a device is missing, it deletes the cached Xcode-managed profiles (`Provisioning.removeXcodeManagedProfiles`: `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, only ones marked `IsXcodeManaged` or named "iOS Team Provisioning Profile…") and builds once more, but only when the profile at fault is Xcode-managed and something was deleted (`canRefreshProfiles`); if that rebuild fails, the first build is still deployed to the devices it covers. A device still missing after that fails with "isn't in the team's provisioning profile" and no install attempt (`PipelineRunner.deploy` checks again, also for redeploys).
6. It deploys to all devices of that platform at the same time with `Deployer` (`PipelineRunner.deployAll`, a task group; with several devices their log lines are prefixed `[device name]`). Platforms still go one after another, because the next build overwrites products. Per-device outcomes go into a `RunRecord`, and the full log goes to `~/Library/Logs/Orchard/<id>/`. Each phase is timed (`RunTimings`, on the `RunRecord` and in the log). `PipelineHistory` persists the runs (`runs.json`, rewritten on every change; unfinished runs load as interrupted) and the window's log (`activity.jsonl`) next to the run logs, writing on a background queue. Line caps cut at a run boundary (`keepingLines`). Both keep `config.keptRuns` builds: each check that starts a run trims the log to the previous `keptRuns - 1` runs (`keepingRuns`, by `LogLine.startsRun`), with 2000 lines as a hard cap on top. A launch that fails after a successful install (a locked phone) is a `.warning`, not a failure: the run still counts as deployed (`RunRecord.finalOutcome`). Each run keeps the apps it built (`RunRecord.products`) while they're still in DerivedData; any new build removes them from older runs (`forgetProducts`), because it overwrites them, embedded apps included (an iOS build rewrites its watch app). A cancelled run marks the devices it didn't finish as failed. A failed or warned device whose app is still there can be deployed again from the deploy list (`PipelineRunner.redeploy`), which appends to the run's log and recomputes its outcome.

## Automatic device setup

Opt-in (`AppStore.setsUpDevicesAutomatically`, UserDefaults key `setsUpDevicesAutomatically`, off by default), for a headless Mac. With it off, nothing below runs: no polling, no pairing, no device added to a pipeline.

1. While it's on, `AppStore` runs `DeviceDiscovery.discover()` every 10 seconds and hands the physical devices to `onboard(_:)`.
2. Setup starts only for a device that shows up unpaired on a cable (`DeviceOnboarding.shouldStart`); devices the user paired are never touched. Its identifier is saved (`onboardingDevices`), so setup carries on after a relaunch.
3. Each poll, `DeviceOnboarding.nextStep(for:)` decides from devicectl's fields alone: `pair` (`devicectl manage pair`, which fails until Trust is tapped and is simply asked again), wait (Developer Mode off, unreachable), or `prepare` (`devicectl device info ddiServices`, which mounts the developer disk image). There's no step for Wi-Fi: pairing is what lets CoreDevice reach the device on the local network.
4. When `prepare` succeeds the device is appended to every pipeline with `addsNewDevices` (`deploysToNewDevices ?? true`), and enabled pipelines run `PipelineRunner.deploy(toNew:)`: a run for just that device, built with `-destination id=<udid>`, because xcodebuild registers only its destination device with the team and a generic destination has none.
5. State shows on the device row (`DiscoveredDevice.onboarding`) and every change goes to `~/Library/Logs/Orchard/devices.log` (`DeviceLog`). Never add a state that needs someone at the Mac.

`devicectl`'s JSON is read from its `properties` dictionary, falling back to the deprecated `connectionProperties`/`deviceProperties`/`hardwareProperties`. `connection.state` is `connected`, `disconnected` (reachable, tunnel down; devicectl connects on demand) or `unavailable`; `transportType` is `wired` or `localNetwork`.

## Builder and clients

Both are opt-in and independent (a Mac can be both). With neither on, Orchard opens no port and contacts no other Mac.

- **Builder** (`AppStore.sharesBuilds`, defaults key `sharesBuilds`): after each successful build of a non-simulator platform, `PipelineRunner.run` calls `SharedBuilds.publish`, which zips the app (`ditto`) to `Pipelines/<id>/Shared/<build id>.zip` with a `<platform>.json` (`SharedBuild`, with a new `id` per build; the archive is named after the build, so a request can't get another build's archive). Platforms a run no longer builds are removed, and turning sharing off removes everything (`SharedBuilds.removeAll`). `BuildServer` listens on `BuilderLink.defaultPort` (8642) and serves only those files: `GET /v1/builds` (`BuildCatalog`), `GET /v1/builds/<pipeline>/<build id>.zip`, `GET /v1/device-support.pkg`. `URLSession` reports a cancelled task as `URLError.cancelled`; `BuilderClient` turns that into `CancellationError`, which is what the runner treats as a cancel. Every request needs `Authorization: Bearer <token>` (`sharingToken` in defaults). It never serves from DerivedData, which the next build overwrites. `PipelineConfig.alsoBuilds` adds a platform no local device needs; a pipeline may then have no devices at all, so a failed build must fail the run itself (`conclude(buildFailed:)`).
- **Client** (`AppStore.builderLink`, defaults key `builderLink`, the string `http://host:port/#token`): `AppStore.sync(with:)` adds a disabled pipeline with `PipelineConfig.remoteID` for each pipeline the builder shares, once (`knownBuilderPipelines`; cleared when the link changes). Such a pipeline has no repo: `PipelineRunner.check` goes to `checkRemote`, which compares the build ids of its devices' platforms with `lastRemoteBuild` (ids, not commits: the builder rebuilds a commit when a profile changes; per platform, because the builder publishes platforms minutes apart, so a run covers only the devices whose platform has a new build) and `runRemote` downloads, unpacks to `Pipelines/<id>/Downloads/<platform>/` and deploys through the same `deployAll` as a local run, so history, redeploy and the provisioning check work unchanged.
- **No Xcode on a client.** `/usr/bin/xcrun` and `/usr/bin/git` are stubs there that pop up "install developer tools", so never call them without checking: `devicectl` goes through `Shell.devicectl` (Xcode's when there is one, else `DeviceSupport.standalonePath`), and simulators are only listed when `DeviceSupport.hasXcode`. The standalone `devicectl` is installed by `XcodeSystemResources.pkg`, which the builder serves from its own Xcode and the client installs with `installer` as root, only if `pkgutil --check-signature` says "signed Apple Software". Not verified on a Mac that never had Xcode: no such Mac was available.
- The wire format (`/v1/…`, `BuildCatalog`, `SharedBuild`) is shared between Orchard versions on different Macs. Add optional fields; don't rename or remove.

## Build, run, test

```bash
swift build                    # debug build
swift test                     # all tests
./scripts/build-app.sh         # release Orchard.app in build/
./scripts/build-app.sh --install
```

You can also open `Package.swift` in Xcode. `swift run` works too: `AppDelegate` sets the activation policy so the bare executable gets a window.

## Tests

- Tests live in `Tests/OrchardTests/`, one file per area: `BuildPlatformTests`, `PipelineConfigTests`, `XcodeTests`, `GitTests`, `ShellTests`, `ContentViewLayoutTests`, `ActivityViewLayoutTests`, `DeployOutcomeTests`, `UpdaterTests`, `PipelineHistoryTests`, `DeviceDiscoveryTests`, `DeviceOnboardingTests`, `ProvisioningTests`, `SharingTests` (which starts a real `BuildServer` on a free localhost port and gives runners a temporary `sharedRoot`), `ParallelDeployTests` (which gives `PipelineRunner` a fake `deployer`, so deploys run without devices). `TemporaryDirectory` is the shared helper for throwaway directories.
- `WindowHarness` hosts a SwiftUI view in a real `NSWindow`, so tests can drive and check the AppKit layout SwiftUI produces (split views, column widths) and render PNGs without Screen Recording permission. Its `OffscreenWindow` sits far off screen and behind everything, so test runs never cover the developer's windows. It still caps its size at the screen's, as AppKit does for on-screen windows (the layout tests pass on CI only with that cap); keep any new test windows off screen the same way (an `NSAlert` panel can't be moved off screen, so lay it out with `layout()` and render it without ordering it in). `makeTestStore()` gives an in-memory `AppStore` (no history on disk) without device discovery; never build one on `.standard` in tests. For automatic setup, pass fake `DeviceOnboarding.Commands` to `AppStore`, feed `onboard(_:)` the `PhysicalDevice`s of each poll and `await onboardingSettled()`; tests must never run the real `devicectl manage pair`.
- `ORCHARD_SCREENSHOTS=<dir> swift test --filter screenshots` renders the main window in light and dark mode for PR descriptions, including a `deploys` state with sample runs and expanded commit list a `devices` state with a mixed device list, a `redeploy` state with a device that can be deployed again, an `onboarding` state with a device in each automatic-setup state, the Settings window (`settings-off`, `settings-on`, `settings-builder`, `settings-client`), a `builder` pipeline, and a `client` pipeline with and without device support (`client`, `client-setup`). The Liquid Glass sidebar comes out blank in these renders (the window server draws it); say so in the PR.
- They use `@testable import Orchard`, so test internal (not `private`) symbols. To test something that's `private`, test it through its public entry point, as `GitTests` does for `parseRefs`, or relax it to internal.
- `GitTests` runs real `git` against temporary repos (a bare repo stands in as `origin`). Pass identity with `-c user.name=… -c user.email=…`, because CI has no global git config.
- `ORCHARD_NETWORK_TESTS=1 swift test --filter Updater` downloads the latest real release and stages its app, to check the self-update download path end to end. CI doesn't run it.
- Anything that needs Xcode signing, `devicectl` or real devices can't run in CI. Keep that logic thin, and pull parsing/decision code out into testable functions.
- Add tests for new logic in `Core/`. Views get layout tests through `WindowHarness` when a bug is about layout; otherwise they aren't unit-tested.

## Rules and gotchas

- **Persisted config is user data.** `PipelineConfig` is JSON-encoded into `UserDefaults` (key `pipelines`). Synthesized `Codable` ignores default values when decoding, so adding a non-optional property makes old saved data fail to decode, and every user loses their pipelines. Make new properties optional, or write a custom `init(from:)`, and add a test that decodes the old shape. The same goes for `RunRecord` in `runs.json` (if it fails to decode, the file is moved to `runs-unreadable.json` and the deploy list starts empty) and `LogLine` in `activity.jsonl` (lines that don't decode are dropped).
- **`Device.id` isn't the UDID.** For physical devices it's devicectl's identifier; provisioning profiles list the hardware UDID, which is `Device.udid` (nil for devices saved before 1.0.11; `PipelineRunner.rememberingUDIDs` looks it up and saves it). `Provisioning` functions take the profile directory as a parameter; tests must pass a temporary one, never the real one.
- **Never touch the user's checkout** beyond `git fetch`. All builds happen in the private worktree.
- **Run every external command through `Shell`**. It provides the login-shell PATH, cancellation and log streaming. Use absolute paths for system tools (`/usr/bin/git`, `/usr/bin/xcrun`, `/usr/bin/xcodebuild`).
- **Concurrency:** Swift 6 language mode with strict concurrency. `AppStore` and `PipelineRunner` are `@MainActor @Observable`. Log callbacks are `@Sendable` and may be called off the main actor.
- **Main window layout:** one three-column `NavigationSplitView`. Don't nest an `HSplitView` in a column: on macOS 26 the columns extend under the floating sidebar, so a nested horizontal split view's minimum width grows with the sidebar until the window overflows. A `VSplitView` (as in `ActivityView`) is fine. `Layout.windowMinWidth` must fit every column's minimum.
- **App icon:** edit `Resources/AppIcon.icon` in Icon Composer (or its `icon.json`/SVGs directly). `build-app.sh` passes `actool` absolute paths, because it resolves relative ones in a helper process with a different cwd.
- **Self-update** shows its windows non-modally (`UpdateWindow`, `AlertPresenter`), never with `runModal()`: a modal run loop started from a main-actor task blocks every other main-actor job, so all pipelines would stop until the alert is answered. It relies on the release tag format `v<VERSION>(<build>)`, a `.dmg` asset holding `Orchard.app`, and the bundle id `se.ambi.Orchard`. Changing any of these in `release.yml` or `build-app.sh` breaks updating for everyone already installed. **Install Updates Automatically** (`Updater.installsAutomatically`, defaults key `automaticallyInstallUpdates`, off by default) is the opt-in for headless Macs; the key is documented for `defaults write`, so don't rename it. `Updater.action` decides between prompting and installing. An unattended install must never show an alert per attempt or stop a running pipeline (it waits in `waitUntilIdle`), and a release whose swap failed (`failedUpdateTag`) isn't installed again, or Orchard would quit and relaunch every hour. The swap runs in a detached `/bin/sh` script (`Updater.swapScript`), not through `Shell`, because it has to outlive the app.
- Keep `README.md` and the screenshots in `docs/` current when you change behavior or UI. The marketing site is a separate repo, [ambiapps/orchard-web](https://github.com/ambiapps/orchard-web). Update it when you add or change user-facing features.

## Fixing bugs

Work every bug the same way, and do it yourself rather than asking the maintainer to check:

1. **Reproduce it first**, ideally as a failing test. For UI bugs, use `WindowHarness` to recreate the state (for example, drag a split view divider with `setPosition(_:ofDividerAt:)`) and print the frames. Don't run the app against the user's real pipelines: `swift run` keeps its own defaults, but tests must use `makeTestStore()`.
2. **Find the root cause** before changing code, and fix that, not the symptom.
3. **Write a regression test** that fails on `main` and passes with the fix. Check it really fails on `main` (for example, in a throwaway `git worktree` of `main` with just the new test copied in).
4. **Verify the fix** with `swift test`, and for UI changes render before/after screenshots in light and dark mode (`ORCHARD_SCREENSHOTS`), then look at them.
5. **Update this file** if the bug revealed a rule or gotcha future agents need.
6. **Open a PR** that explains the root cause, the fix and how it was verified, with the screenshots. Have a separate agent review the PR and address its findings. Merge only if the maintainer asked you to (with a merge commit, once `Build & test` passes); otherwise leave it for them.

## Workflow

- `main` is protected. Changes land only through PRs, the `Build & test` check must pass, and only the maintainer (@JagCesar) can merge. Don't try to push to `main`.
- Work on a branch, keep each PR to one topic, and run `swift test` before pushing.
- Never rebase or squash. To catch up with `main`, merge `main` into your branch. PRs are merged with merge commits.
- **Bump the patch version in every PR.** Each merge to `main` publishes a release, so every PR increments the last digit of `VERSION` (e.g. `1.0.1` → `1.0.2`); the build number in parentheses comes from CI on its own. Bump minor or major only if the maintainer asks. If `main`'s `VERSION` moved while your PR was open, merge `main` and bump again from its value, so two releases never share a version.
- For UI changes, put screenshots in the PR description: before/after for changed screens, in both light and dark mode. Orchard is macOS-only.
