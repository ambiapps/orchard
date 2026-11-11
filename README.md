# Orchard

A macOS app that watches a git branch and, whenever it moves, builds the app and deploys it to the devices you pick — this Mac, paired iPhones/iPads/Apple TVs/Vision Pros, and booted simulators.

![Orchard](docs/screenshot-light.png)

## Build & run

```bash
./scripts/build-app.sh --install
```

This builds `build/Orchard.app` and copies it to `~/Applications`. You can also open `Package.swift` in Xcode and run it.

Run the tests with `swift test`. CI runs them, plus the app bundle build, on every pull request.

## Releases

Every push to `main` builds a DMG (`./scripts/build-dmg.sh`) and publishes it as a [GitHub release](https://github.com/ambiapps/orchard/releases) tagged `v<version>(<build>)`, e.g. `v1.0.0(42)`. The version comes from [`VERSION`](VERSION); the build number is the CI run number. The app is ad-hoc signed, not notarized, so after the first launch attempt allow it in **System Settings › Privacy & Security › Open Anyway** (or run `xattr -dr com.apple.quarantine /Applications/Orchard.app`).

Orchard checks for a new release each time it starts. When one is out it shows a small **Update Available** window with a link to the release notes: **Install and Relaunch** downloads the DMG, replaces the app in place and reopens it; **Skip This Version** stops the reminders for that release. **Check for Updates…** is in the app menu and the menu bar menu. Self-updating needs write access to the folder Orchard lives in; otherwise the pop-up links to the download.

On a Mac nobody sits at (a build machine you reach over SSH or screen sharing), turn on **Install Updates Automatically** in the app menu or the menu bar menu, or from a shell:

```bash
defaults write se.ambi.Orchard automaticallyInstallUpdates -bool YES
```

Orchard then checks for a release every hour and installs it without asking. It waits for running builds and deploys to finish first, and relaunches with the same pipelines enabled. It's off by default, and a `defaults write` on a running Orchard takes effect within the hour. A version you skipped stays skipped. A download that fails is tried again at the next check; a release that downloaded but couldn't replace the app isn't.

## Using it

1. **+** to add a pipeline, then **Choose…** a local clone of the repo.
2. Pick the branch, project/workspace, scheme, configuration and devices.
3. Toggle **Enable** in the toolbar. Orchard checks the branch head (`git ls-remote`) every poll interval and, when it changes, builds and deploys. **Build & Deploy Now** forces a run.

Orchard keeps running in the menu bar after the window closes.

## How it works

- **Checkout:** a private detached `git worktree` per pipeline in `~/Library/Application Support/Orchard/Pipelines/<id>/` — your own checkout is never touched (other than `git fetch`).
- **Build:** one `xcodebuild build` per platform (`generic/platform=iOS`, `platform=macOS`, …) with automatic signing (`-allowProvisioningUpdates`), so all iPhones and iPads share one build. Builds are incremental (each pipeline keeps its own DerivedData) and skip dSYMs (`DEBUG_INFORMATION_FORMAT=dwarf`), which deploys don't need. If the app's provisioning profile doesn't list a chosen device (Xcode's cached profile predates it), Orchard deletes Xcode's cached managed profiles and builds once more; a device that's still missing fails with a message to register it. A build phase that requires a dSYM, such as a strict crash-reporter upload script, won't find one.
- **Deploy:** `devicectl device install app` + `process launch --terminate-existing` for devices, `simctl install/launch` for simulators, quit + `open` for this Mac. Devices that share a build are deployed to at the same time.
- **Crashes:** on every poll, Orchard looks for new crash reports of the deployed app (`devicectl device info files --domain-type systemCrashLogs` on devices, `~/Library/Logs/DiagnosticReports` for simulators and this Mac). Each crash goes into the log with its exception, reason and crashed-thread frames (app frames symbolicated with `atos` against the built app), posts a notification, and its `.ips` is kept in `~/Library/Logs/Orchard/<id>/crashes/`.
- A commit that fails isn't retried on every poll; push a new one or use **Build & Deploy Now**.
- If the app installs but can't launch (for example, the phone is locked), the deploy shows a warning instead of failing and counts as deployed.
- When a device fails or the app doesn't launch on it (disconnected, locked), click its name in the deploy to install and launch the same build on it again, without rebuilding. That works for the most recent build, until the next one starts.
- Each deploy lists the commits it brings in since the last successful deploy (`git log <last>..<new>`, up to 50). Nothing is listed when the new commit doesn't descend from the last one (force-push, rollback, branch switch).
- Full logs per run are in `~/Library/Logs/Orchard/<id>/`. The deploy list and the log in the window are kept there too (`runs.json`, `activity.jsonl`), so they survive a relaunch. Both keep the last 20 builds (set per pipeline under Polling; lowering it trims right away), and both show how long checkout, build and deploy took.

## Requirements

macOS 15+, Xcode with a signed-in developer account for physical devices, and devices that are paired with Xcode and have Developer Mode on. Devices must be registered in your team (deploying once from Xcode does this).
