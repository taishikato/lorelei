# Plan 007: Add a "Check for Updates" to settings backed by GitHub Releases

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- Lorelei/CompanionPanelView.swift Lorelei/LoreleiAnalytics.swift LoreleiTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (additive UI + one network call; no auto-install)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

Lorelei now ships as a notarized DMG from GitHub Releases, but nothing in the
app knows releases exist - every install is permanently stranded on its
version unless the user re-visits GitHub by chance. Full auto-update (Sparkle:
appcast hosting, EdDSA keys, release.sh changes) is deliberately deferred; the
80% win at 20% cost is a manual "Check for Updates" that compares the running
version against the latest GitHub release and opens the release page. This
also creates the seam (version comparison, release lookup) that a later
Sparkle migration would reuse.

## Current state

- Current version surfaces from the bundle:
  `Lorelei/CompanionPanelView.swift:397-398`:

```swift
private var appVersion: String {
    "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
}
```

  Marketing version is set via build setting (currently `1.0`); release tags
  are `v<version>` (existing: `v1.0`).
- The settings window content is `Lorelei/CompanionPanelView.swift` (510
  lines): sections built with the `section(_:content:)` helper; rows are
  `HStack`s padded 8 with `.background(rowBackground)`; buttons use
  `.buttonStyle(.plain)` + `.pointerCursor()`. `generalSection` (line ~93)
  currently holds the Launch at Login row - the new row goes in this section.
  Row typography: title `.system(size: 12, weight: .medium)` primary,
  subtitle `.system(size: 10, weight: .medium)` secondary, leading SF Symbol
  12pt medium secondary in an 18pt frame.
- Actions that mutate view state from buttons must be wrapped in
  `deferredAction { ... }` (see the comment on `deferredAction` in
  `Lorelei/LoreleiToolbarView.swift` - synchronous teardown inside a button
  callback crashes SwiftUI; every settings/toolbar button already follows
  this).
- GitHub API: `GET https://api.github.com/repos/taishikato/lorelei/releases/latest`
  returns JSON with `tag_name` (e.g. `"v1.0"`) and `html_url`. Unauthenticated
  rate limit is 60/hour/IP - fine for a manual button.
- Analytics: `Lorelei/LoreleiAnalytics.swift` - enum `LoreleiAnalyticsEvent`
  with `name` + `properties`; names are pinned by
  `LoreleiTests/LoreleiAnalyticsTests.swift` `eventNamesAreStable()`. The
  privacy contract at the top of the file forbids content; version strings
  are fine (coarse metadata).
- Repo conventions: `@MainActor final class ... : ObservableObject` stores
  with injected dependencies for testability (exemplar:
  `Lorelei/AudioInputDeviceStore.swift` - protocol seam
  `AudioInputDeviceEnumerating` + `CoreAudioInputDeviceEnumerator` +
  injectable `UserDefaults`); pure logic gets unit tests with fakes.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData test -test-timeouts-enabled YES -default-test-execution-time-allowance 60` | `** TEST SUCCEEDED **` |
| API sanity (read-only) | `curl -s https://api.github.com/repos/taishikato/lorelei/releases/latest \| python3 -c "import json,sys; d=json.load(sys.stdin); print(d['tag_name'], d['html_url'])"` | prints a tag and URL |

## Scope

**In scope**:
- `Lorelei/UpdateChecker.swift` (create)
- `Lorelei/CompanionPanelView.swift` (add one row to `generalSection`)
- `Lorelei/LoreleiAnalytics.swift` (one new event case) +
  `LoreleiTests/LoreleiAnalyticsTests.swift` (extend the pinned-names test)
- `LoreleiTests/UpdateCheckerTests.swift` (create)

**Out of scope** (do NOT touch):
- Sparkle or any auto-download/install mechanism.
- `scripts/release.sh`, entitlements, Info.plist.
- Scheduled/背景 checks (no timers; manual button only).

## Git workflow

- Branch: `update-check`
- Commit style: `feat: manual update check against GitHub releases`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create UpdateChecker with a fetch seam

`Lorelei/UpdateChecker.swift`, modeled on `AudioInputDeviceStore.swift`:

- `struct UpdateCheckResult: Equatable { let latestVersion: String; let releaseURL: URL; let isNewer: Bool }`
- `protocol LatestReleaseFetching { func fetchLatestRelease() async throws -> (tagName: String, htmlURL: URL) }`
- `struct GitHubLatestReleaseFetcher: LatestReleaseFetching` - URLSession GET
  of the API URL above, decode via a private `Decodable` struct
  (`tag_name`, `html_url`), 10s timeout.
- `@MainActor final class UpdateChecker: ObservableObject`:
  - `enum State: Equatable { case idle, checking, upToDate(String), updateAvailable(UpdateCheckResult), failed(String) }`,
    `@Published private(set) var state: State = .idle`.
  - `init(fetcher: LatestReleaseFetching = GitHubLatestReleaseFetcher(), currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")`.
  - `func check() async` - sets `.checking`, fetches, compares, sets terminal
    state; errors become `.failed` with a short message (never crash).
  - **Pure, testable comparison**: `static func isVersion(_ candidate: String, newerThan current: String) -> Bool`
    - strip a leading `v`/`V`, split on `.`, compare numeric components
    left-to-right (missing components = 0); non-numeric components compare as
    0 (be lenient - a malformed tag must not crash).

**Verify**: build succeeds.

### Step 2: Add the settings row

In `CompanionPanelView.generalSection`, add a second row (after Launch at
Login, same row chrome): SF Symbol `arrow.triangle.2.circlepath`, title
"Check for Updates", subtitle bound to the checker state ("You're on
\(appVersion)" when idle, "Checking..." while checking, "Up to date" /
"vX.Y available" / error text). Trailing control: a small button - "Check"
when idle/terminal, disabled while checking; when `.updateAvailable`, a
second "Open Release Page" button that calls
`NSWorkspace.shared.open(result.releaseURL)`. All button actions wrapped in
`deferredAction { ... }`; the async check launched via `Task { await checker.check() }`.
Hold the checker as `@StateObject private var updateChecker = UpdateChecker()`.

**Verify**: build succeeds; run the app
(`open -a "$PWD/DerivedData/Build/Products/Debug/Lorelei.app"`), open settings
via the toolbar gear, click Check → with network, expect "Up to date" (local
build version equals the latest release) or a version offer; the app must not
beachball (check is async).

### Step 3: Analytics event

Add case `updateCheckPerformed(updateAvailable: Bool)` → name
`"update_check_performed"`, properties `["update_available": Bool]`. Capture
it in `UpdateChecker.check()` on the two success terminals only (not on
`.failed`). Extend `eventNamesAreStable()` in
`LoreleiTests/LoreleiAnalyticsTests.swift` with the new name.

**Verify**: build succeeds; analytics test passes.

### Step 4: Unit tests

`LoreleiTests/UpdateCheckerTests.swift` (pattern:
`LoreleiTests/LoreleiAnalyticsTests.swift` for file shape; fakes like
`FakeAudioInputDeviceEnumerator` in `LoreleiTests/LoreleiTests.swift:3990+`
for the seam style). Cases:

1. `isVersion("v1.1", newerThan: "1.0")` → true; `("v1.0","1.0")` → false;
   `("1.0.1","1.0")` → true; `("0.9","1.0")` → false; `("v2","1.9.9")` → true;
   malformed `("vNext","1.0")` → false (no crash).
2. `check()` with a fake fetcher returning `v9.9` → state
   `.updateAvailable`, result fields populated.
3. `check()` with fake returning the current version → `.upToDate`.
4. `check()` with a throwing fake → `.failed` (message non-empty).

**Verify**: full test command → `** TEST SUCCEEDED **`.

## Test plan

Step 4 (6+ cases) plus the extended analytics-names test. No network in
tests - the fake fetcher covers all `check()` paths.

## Done criteria

- [ ] Full suite passes including `UpdateCheckerTests`
- [ ] Settings shows the row; manual click round-trips against the real API
      (step 2 verification)
- [ ] `grep -n "update_check_performed" Lorelei/ -r` → exactly one definition
- [ ] `git diff --stat` touches only the five in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- The releases API shape differs from `tag_name`/`html_url` (verify with the
  curl command first) - report.
- `generalSection` in `CompanionPanelView.swift` no longer matches the
  described structure (drift from another plan landing first) - re-read and
  adapt only if the change is mechanical; otherwise report.
- Any requirement to store credentials or tokens appears - this plan is
  unauthenticated-only by design; stop rather than adding a token.

## Maintenance notes

- Release discipline: the comparison trusts `tag_name` (`vX.Y[.Z]`) matching
  `CFBundleShortVersionString`. Future releases must keep tagging `v<version>`
  and bumping the marketing version together (release.sh reads the built
  Info.plist, so the pairing is natural).
- This is the stepping stone to Sparkle: `LatestReleaseFetching` and the
  version comparator are reusable; if full auto-update is built later, delete
  the row's "Open Release Page" flow in favor of Sparkle's UI.
- Plan 002's README Privacy/Download sections may mention the update check
  once this lands (one line; optional).
