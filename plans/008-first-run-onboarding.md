# Plan 008: Add a guided first-run onboarding for DMG users

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- Lorelei/LoreleiApp.swift Lorelei/SettingsWindowController.swift Lorelei/CompanionPanelView.swift Lorelei/LoreleiAnalytics.swift LoreleiTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW-MED (additive UI; touches the launch path)
- **Depends on**: none (if plan 004 landed, CompanionPanelView line numbers
  will have shifted - rely on symbol names, not line numbers)
- **Category**: direction
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

Lorelei needs four macOS permission grants (two requiring System Settings
round-trips) plus a workspace folder before it does anything useful. Today's
first run just auto-opens the settings window when permissions are missing - a
bare panel of Grant buttons with no explanation of what the app is, why it
needs each permission, or how to talk to it. Source-builders tolerate that;
DMG users (the new audience since v1.0) churn silently at exactly this cliff.
A short guided flow - welcome → permissions with rationale → workspace +
"hold Control+Option to talk" - directly attacks day-one drop-off, and the
existing analytics can measure completion.

## Current state

- Launch wiring - `Lorelei/LoreleiApp.swift` (`CompanionAppDelegate
  .applicationDidFinishLaunching`, lines ~49-83): creates
  `SettingsWindowController` + `LoreleiToolbarController`, wires
  `onOpenSettings`, calls `companionManager.start()`, shows the toolbar, then:

```swift
// Auto-open settings only when permissions are missing or revoked.
if !companionManager.allPermissionsGranted {
    settingsWindowController?.show()
}
```

- `Lorelei/SettingsWindowController.swift` (56 lines) - THE pattern for a
  standard AppKit window in this app: `@MainActor final class ... : NSObject,
  NSWindowDelegate`, lazy `NSWindow(contentViewController: NSHostingController(...))`,
  `styleMask [.titled, .closable, .miniaturizable]`,
  `isReleasedWhenClosed = false`, `isMovableByWindowBackground = true`,
  `center()`, and the activation-policy dance:
  `show()` does `NSApp.setActivationPolicy(.regular)` +
  `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront`;
  `windowWillClose` restores `.accessory`. Mirror this exactly.
- Permission state - `Lorelei/CompanionManager.swift`: published
  `hasMicrophonePermission`, `hasAccessibilityPermission`,
  `hasScreenRecordingPermission`, `hasScreenContentPermission`;
  `allPermissionsGranted` (line ~160) ANDs all four. Permission-request UI
  lives in `Lorelei/CompanionPanelView.swift` as private computed rows:
  `microphonePermissionRow`, `accessibilityPermissionRow`,
  `screenRecordingPermissionRow`, `screenContentPermissionRow`, built on the
  `permissionRow(title:iconName:isGranted:action:)` helper. The actions call
  `AVCaptureDevice.requestAccess`, `WindowPositionManager
  .requestAccessibilityPermission()`, `...requestScreenRecordingPermission()`,
  and `companionManager.requestScreenContentPermission()`.
- Workspace selection - `CompanionPanelView.swift` `workspaceSection` opens an
  NSOpenPanel and writes `workspaceStore.selectedWorkspacePath`
  (`WorkspaceSettingsStore`, injected `UserDefaults`). Read it before step 3
  and reuse its action logic.
- Hotkey keycap rendering to reuse (welcome page) -
  `Lorelei/LoreleiToolbarView.swift` `conversationEmptyState` renders
  `BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels` as small
  rounded-rect keycaps; the face is `LoreleiFaceView(expression: .neutral,
  audioLevel: 0)`.
- Analytics - `Lorelei/LoreleiAnalytics.swift` enum + pinned-names test
  `eventNamesAreStable()` in `LoreleiTests/LoreleiAnalyticsTests.swift`.
- Button convention: state-mutating button actions wrapped in
  `deferredAction { ... }` (documented on `deferredAction` in
  `LoreleiToolbarView.swift`).
- Persistence convention: injected `UserDefaults` with a `static let ...DefaultsKey`
  (exemplar: `WorkspaceSettingsStore.swift`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData test -test-timeouts-enabled YES -default-test-execution-time-allowance 60` | `** TEST SUCCEEDED **` |
| Reset the flag for manual runs | `defaults delete dev.taishi.lorelei hasCompletedLoreleiOnboarding` | exit 0 (or "does not exist") |

## Scope

**In scope**:
- `Lorelei/OnboardingWindowController.swift` (create)
- `Lorelei/OnboardingView.swift` (create; may contain a small
  `LoreleiOnboardingState` helper)
- `Lorelei/PermissionRowsView.swift` (create - extraction target)
- `Lorelei/CompanionPanelView.swift` (refactor `voiceSection` to use the
  extracted rows; no visual change)
- `Lorelei/LoreleiApp.swift` (launch gating)
- `Lorelei/LoreleiAnalytics.swift` + `LoreleiTests/LoreleiAnalyticsTests.swift`
- `LoreleiTests/OnboardingTests.swift` (create)

**Out of scope** (do NOT touch):
- The permission-request implementations (`WindowPositionManager`,
  `CompanionManager.requestScreenContentPermission`) - reuse, don't modify.
- The toolbar, dictation, or Codex pipeline.
- Any change to WHAT permissions are required.

## Git workflow

- Branch: `first-run-onboarding`
- Commit style: `feat: guided first-run onboarding`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extract PermissionRowsView

Create `Lorelei/PermissionRowsView.swift`: a SwiftUI view taking
`@ObservedObject var companionManager: CompanionManager` and rendering the
four permission rows exactly as `CompanionPanelView` does today - MOVE the
four `...PermissionRow` computed properties and the
`permissionRow(title:iconName:isGranted:action:)` helper (plus whatever
private styling they use, e.g. `rowBackground` - duplicate small style
helpers rather than widening `CompanionPanelView` access). Refactor
`CompanionPanelView.voiceSection` to embed `PermissionRowsView(companionManager:)`
in place of the four rows (the Input Device row stays where it is).

**Verify**: build succeeds; open settings in the running app - the Voice
section looks unchanged.

### Step 2: Onboarding state + window controller

- In `OnboardingView.swift` (or a small separate type):
  `enum LoreleiOnboarding { static let completedDefaultsKey = "hasCompletedLoreleiOnboarding"; static func shouldShow(defaults: UserDefaults = .standard) -> Bool { !defaults.bool(forKey: completedDefaultsKey) } }`
- `Lorelei/OnboardingWindowController.swift`: mirror
  `SettingsWindowController.swift` verbatim in structure (window style,
  activation-policy toggling, `isReleasedWhenClosed = false`), hosting
  `OnboardingView`, title "Welcome to Lorelei", content width ~460. Add an
  `onFinished: (() -> Void)?` the view calls; the controller closes the
  window in it.

**Verify**: build succeeds.

### Step 3: The three onboarding pages

`OnboardingView` with `@State private var step: Int = 0` and a bottom-trailing
primary Continue button (wrapped in `deferredAction`):

1. **Welcome**: `LoreleiFaceView(expression: .neutral, audioLevel: 0)` scaled
   up, one short paragraph (what Lorelei is: hold-to-talk voice control that
   drives your Mac through Codex), and the hotkey keycaps rendered like
   `conversationEmptyState` does ("Hold [ctrl] [option] and speak").
2. **Permissions**: one-line rationale per permission (mic = hear you,
   accessibility = read and press UI, screen recording = screenshot fallback,
   screen content = screen questions) above `PermissionRowsView`. Continue is
   always enabled; when `!companionManager.allPermissionsGranted`, label it
   "Continue anyway" so partial grants don't trap the user.
3. **Workspace & finish**: current workspace status + a "Choose Folder"
   button reusing the same NSOpenPanel logic as `CompanionPanelView`'s
   `workspaceSection` (read it first and mirror; write through
   `companionManager.workspaceSettingsStore`), plus a closing line that the
   gear on the floating toolbar opens Settings later. Final button "Start
   Using Lorelei" → set the completed flag, capture analytics, call
   `onFinished`.

**Verify**: build succeeds.

### Step 4: Launch gating + analytics

- `LoreleiApp.swift`: create the onboarding controller alongside the settings
  controller; replace the auto-open block with:

```swift
if LoreleiOnboarding.shouldShow() {
    onboardingWindowController?.show()   // captures .onboardingStarted inside show()
} else if !companionManager.allPermissionsGranted {
    settingsWindowController?.show()
}
```

- `LoreleiAnalytics.swift`: add `onboardingStarted` → `"onboarding_started"`
  and `onboardingCompleted` → `"onboarding_completed"` (no properties).
  Capture started in `OnboardingWindowController.show()` (first show only),
  completed in the finish action. Extend `eventNamesAreStable()`.

**Verify**: build succeeds; `defaults delete dev.taishi.lorelei hasCompletedLoreleiOnboarding`,
launch the app (`open -a "$PWD/DerivedData/Build/Products/Debug/Lorelei.app"`)
→ onboarding window appears; complete it → relaunch → it does NOT appear
(settings auto-open still works if permissions are missing).

### Step 5: Tests

`LoreleiTests/OnboardingTests.swift` (file shape per
`LoreleiTests/LoreleiAnalyticsTests.swift`):

1. `shouldShow` true on a fresh `UserDefaults(suiteName:)`.
2. `shouldShow` false after setting the completed key.
3. (In `LoreleiAnalyticsTests.swift`) the two new event names pinned.

**Verify**: full test command → `** TEST SUCCEEDED **`.

## Test plan

Step 5. UI pages themselves are verified manually in step 4 (window
appearance, once-only gating) - matching how this repo treats window chrome.

## Done criteria

- [ ] Fresh-defaults launch shows onboarding; post-completion launch does not
- [ ] Settings Voice section visually unchanged after the extraction
- [ ] Full suite passes, including the 2 gating tests and extended names test
- [ ] `git diff --stat` touches only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- The four permission rows in `CompanionPanelView.swift` no longer exist as
  described (drift) - report.
- The workspace-selection logic in `workspaceSection` is not reusable as a
  self-contained action (e.g. it is entangled with view-local state beyond
  the store) - report with the actual shape instead of duplicating complex
  logic.
- Showing two policy-toggling windows (onboarding now, settings later)
  fights over `NSApp.setActivationPolicy` - if window close order breaks the
  accessory restore, report; the fix (a shared policy refcount) is a design
  change beyond this plan.

## Maintenance notes

- The onboarding copy hardcodes the hotkey via
  `BuddyPushToTalkShortcut.currentShortcutOption` - if the shortcut becomes
  configurable, the welcome page follows automatically through
  `keyCapsuleLabels`.
- Funnel measurement: `onboarding_started` vs `onboarding_completed` in
  PostHog answers whether the permission cliff is real (the audit's
  assumption) - check after a release before investing more here.
- Deferred deliberately: a "test your first command" interactive step
  (requires a granted-permissions environment mid-flow), localization.
