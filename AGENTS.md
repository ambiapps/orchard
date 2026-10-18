# AGENTS.md

Guide for AI coding agents working on this repo. All of the code here is written by agents, so keep this file accurate: if you change something it describes, update it in the same PR.

## What Orchard is

A macOS menu bar + window app (SwiftUI, macOS 15+) for iOS/macOS developers. You point it at a local git clone, a branch, an Xcode scheme and a set of devices. While a pipeline is enabled, Orchard polls the branch and, whenever its head commit changes, builds the app and installs + launches it on every chosen device: this Mac, paired physical iPhones/iPads/Apple TVs/Apple Watches/Vision Pros, and booted simulators. It's like a tiny local CD server for your own devices.

It shells out to the developer's own tools: `git`, `xcodebuild`, `xcrun devicectl` (physical devices) and `xcrun simctl` (simulators). There's no server and no network code of its own.

## Layout

```
Package.swift                 SwiftPM package: executable target Orchard + test target OrchardTests
Sources/Orchard/
  OrchardApp.swift            @main: main window, menu bar extra, AppDelegate (keeps running after window closes)
  Core/
    Models.swift              BuildPlatform, Device, PipelineConfig (persisted), RunRecord, LogLine
    AppStore.swift            @Observable root state: list of PipelineRunners, discovered devices, persistence
    PipelineRunner.swift      One pipeline: poll loop, run (checkout → build per platform → deploy per device),
                              status, log, run history. Also Paths, LogFile, Notifier
    Git.swift                 Remote/branch queries via ls-remote, private worktree checkout
    Xcode.swift               Finds .xcworkspace/.xcodeproj/Package.swift, lists schemes, builds, locates the .app
    Deployer.swift            Install + launch on this Mac / physical device / simulator
    DeviceDiscovery.swift     Paired devices (devicectl JSON) and booted simulators (simctl JSON)
    Shell.swift               Async Process wrapper with login-shell PATH and line streaming. All commands go through it
  Views/
    ContentView.swift         Sidebar of pipelines + detail split view
    PipelineDetailView.swift  Settings form (repo, branch, container, scheme, configuration, devices, interval)
    ActivityView.swift        Run history and live log
Tests/OrchardTests/           Swift Testing (`import Testing`, `@Test`, `#expect`) unit tests
Resources/AppIcon.icon/       Liquid Glass app icon (Icon Composer document: icon.json + SVG layers)
VERSION                       Marketing version (CFBundleShortVersionString); bump it here
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
4. It runs one `xcodebuild build` per `BuildPlatform` among the chosen devices (generic destination, so all iPhones share one build), then reads `-showBuildSettings -json` to find the `.app`.
5. It deploys to each device of that platform with `Deployer`. Per-device outcomes go into a `RunRecord`, and the full log goes to `~/Library/Logs/Orchard/<id>/`.

## Build, run, test

```bash
swift build                    # debug build
swift test                     # all tests
./scripts/build-app.sh         # release Orchard.app in build/
./scripts/build-app.sh --install
```

You can also open `Package.swift` in Xcode. `swift run` works too: `AppDelegate` sets the activation policy so the bare executable gets a window.

## Tests

- Tests live in `Tests/OrchardTests/`, one file per area: `BuildPlatformTests`, `PipelineConfigTests`, `XcodeTests`, `GitTests`. `TemporaryDirectory` is the shared helper for throwaway directories.
- They use `@testable import Orchard`, so test internal (not `private`) symbols. To test something that's `private`, test it through its public entry point, as `GitTests` does for `parseRefs`, or relax it to internal.
- `GitTests` runs real `git` against temporary repos (a bare repo stands in as `origin`). Pass identity with `-c user.name=… -c user.email=…`, because CI has no global git config.
- Anything that needs Xcode signing, `devicectl` or real devices can't run in CI. Keep that logic thin, and pull parsing/decision code out into testable functions.
- Add tests for new logic in `Core/`. Views aren't unit-tested.

## Rules and gotchas

- **Persisted config is user data.** `PipelineConfig` is JSON-encoded into `UserDefaults` (key `pipelines`). Synthesized `Codable` ignores default values when decoding, so adding a non-optional property makes old saved data fail to decode, and every user loses their pipelines. Make new properties optional, or write a custom `init(from:)`, and add a test that decodes the old shape.
- **Never touch the user's checkout** beyond `git fetch`. All builds happen in the private worktree.
- **Run every external command through `Shell`**. It provides the login-shell PATH, cancellation and log streaming. Use absolute paths for system tools (`/usr/bin/git`, `/usr/bin/xcrun`, `/usr/bin/xcodebuild`).
- **Concurrency:** Swift 6 language mode with strict concurrency. `AppStore` and `PipelineRunner` are `@MainActor @Observable`. Log callbacks are `@Sendable` and may be called off the main actor.
- **App icon:** edit `Resources/AppIcon.icon` in Icon Composer (or its `icon.json`/SVGs directly). `build-app.sh` passes `actool` absolute paths, because it resolves relative ones in a helper process with a different cwd.
- Keep `README.md` and the screenshots in `docs/` current when you change behavior or UI. The marketing site is a separate repo, [ambiapps/orchard-web](https://github.com/ambiapps/orchard-web). Update it when you add or change user-facing features.

## Workflow

- `main` is protected. Changes land only through PRs, the `Build & test` check must pass, and only the maintainer (@JagCesar) can merge. Don't try to push to `main`.
- Work on a branch, keep each PR to one topic, and run `swift test` before pushing.
- Never rebase or squash. To catch up with `main`, merge `main` into your branch. PRs are merged with merge commits.
- For UI changes, put screenshots in the PR description: before/after for changed screens, in both light and dark mode. Orchard is macOS-only.
