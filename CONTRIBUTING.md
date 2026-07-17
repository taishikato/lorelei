# Contributing

Thanks for helping with Lorelei.
This guide covers how to build, test, and land changes without tripping the project's sharp edges.

## Build and test

Open the Xcode project and use the `Lorelei` scheme, or build from the terminal:

```bash
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug \
  -derivedDataPath DerivedData build
```

Run the suite:

```bash
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```

CI (`.github/workflows/ci.yml`) runs the same suite on every PR.

Before merging behavior changes, run the suite **3 times** locally and keep all three green.
Flakes are real bugs here.

## Deflake doctrine

If a test flakes, fix it even when the flake is unrelated to your change.
Prefer raising knife-edge timer margins, injecting controllable clocks / sleeps into fakes, or adding readiness gates.
Do not paper over races with retries.

The suite must not need a real Codex process, microphone, or TCC grants.
Transcription, the App Server protocol, and desktop actions are seams with scripted fakes (`FakeCodexAppServerTransport`, `FakeDesktopActionExecutor`, and friends in `LoreleiTests`).

## Conventions that bite newcomers

- **`deferredAction { ... }` for every SwiftUI button and menu action.**
  Direct actions that tear down the view subtree crash in `MainActor.assumeIsolated`.
- **Text into other apps: AX selects, paste inserts; desktop tools use AX `setValue`.**
  Never synthesize per-character content keystrokes (Japanese IME breaks otherwise).
  See `ARCHITECTURE.md` for the two paths.
- **`PBXFileSystemSynchronizedRootGroup`.**
  New files under `Lorelei/` and `LoreleiTests/` are picked up automatically.
  Do not edit `project.pbxproj` just to add source files.
- **Bundle ID `dev.taishi.lorelei` must never change.**
  Microphone, Accessibility, and Screen Recording grants are tied to it.
- **Analytics stay coarse.**
  `LoreleiAnalytics.swift` carries event names, counts, and durations - never transcripts, conversation text, screen content, or file paths.
  `LoreleiAnalyticsTests` pins the event names; update that test when you add an event.
- **Unique `UserDefaults` suite names.**
  Every suite that touches defaults uses its own suite name and calls `removePersistentDomain`.
- **Commit messages in English**, with plain `-` dashes and `'` quotes in prose.

## Pull requests

- Add tests for new behavior in the same style as neighboring suites.
- Routing changes extend the matrix in `CommandRouterTests`.
- Keep CI green; for behavior changes, also satisfy the local 3x-green rule above.
- Prefer small, reviewable diffs.
  Read `ARCHITECTURE.md` before changing seams or adding `lorelei.*` tools.

## Good first areas

Good starter work usually looks like:

- Docs fixes and clarifications in `README.md`, `ARCHITECTURE.md`, or this file
- New scripted-fake tests around an existing seam
- Small UI polish in the toolbar / settings surfaces

Browse open issues on GitHub for labeled starter tasks rather than assuming a specific issue is free.
If nothing fits, open an issue describing the change before a large PR.
