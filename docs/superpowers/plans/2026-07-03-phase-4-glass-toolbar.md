# Phase 4: Floating Glass Toolbar - Implementation Plan

> **For agentic workers:** Executed by Codex (gpt-5.5) task-by-task, reviewed by the planner between tasks. Codex must not run git commands that write; the reviewer stages and commits. Codex builds with `-derivedDataPath ./DerivedData build-for-testing`; the reviewer runs tests.

**Goal:** Replace the menu-bar-anchored status UI with a floating liquid-glass toolbar at the top-center of the screen: collapsed it shows live status (listening / transcribing / working / needs approval), clicked it expands to the current turn's stream, tool activity, a stop button, and approval buttons. The menu bar item shrinks to a settings/quit popover.

**Why now:** The phase 3 live test showed the menu bar is unusable as an anchor - with a crowded menu bar the status item (and the panel positioned beneath it) is pushed behind the notch and becomes invisible.

**Architecture:** A new observable turn-state model on CompanionManager (`runStatus`, `streamText`, `currentActivity`) is fed by a progress callback from CodexAppServerExecutor (agent message deltas + tool start/finish, which the executor already parses). The toolbar is a non-activating floating NSPanel owned by a new LoreleiToolbarController, whose SwiftUI content renders purely from CompanionManager state. Stop works by terminating the live transport (the executor already ends the turn as failed when the transport dies - same path as timeout).

**Tech Stack:** SwiftUI with macOS 26 liquid glass APIs (`.glassEffect` family / `GlassEffectContainer`; verify exact names against the SDK - tests must not assert on glass rendering), NSPanel (`.nonactivatingPanel`, `.statusBar` level), Swift Testing with the existing scripted-frame fixtures.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md` decisions #2, #10 (toolbar = current turn stream + tool activity + stop + approval ONLY; no history, no text input) and #5 (approval bridge stays).
- The cursor-side waveform overlay (`OverlayWindow`) is phase 5 territory - do not touch it.
- UI views stay thin: no business logic in SwiftUI views; everything renders from published CompanionManager state so logic is testable without UI.
- Build: `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData build-for-testing`
- Reviewer test command: `xcodebuild test ... -skip-testing:LoreleiUITests -test-timeouts-enabled YES -default-test-execution-time-allowance 60`
- Commit messages in English; one commit per task by the reviewer.

---

### Task 1: Turn progress state model

**Files:**
- Modify: `Lorelei/CodexAppServerExecutor.swift` (progress callback)
- Modify: `Lorelei/CompanionManager.swift` (published state)
- Create: `Lorelei/LoreleiRunStatus.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Produces:

```swift
enum LoreleiRunStatus: Equatable, Sendable {
    case idle
    case listening                 // push-to-talk held
    case transcribing              // key released, waiting for final transcript
    case working(String)           // turn running; associated value = short activity label
    case needsApproval(String)     // approval request title
    case finished(success: Bool)   // terminal, shown briefly then back to idle
}

enum CodexAppServerTurnProgress: Equatable, Sendable {
    case agentMessageDelta(String)
    case toolCallStarted(name: String)      // e.g. "lorelei.desktop_snapshot"
    case toolCallCompleted(name: String, success: Bool)
}
typealias CodexAppServerTurnProgressHandler = @Sendable (CodexAppServerTurnProgress) -> Void
```

- `CodexAppServerExecutor.init` gains `progressHandler: @escaping CodexAppServerTurnProgressHandler = { _ in }` and invokes it from the existing parse points: the `.agentMessageDelta` case, dynamic tool call start/completion (the executor already knows the tool name where it dispatches `dynamicToolHandler`), and mcp/other `toolCallCompleted` events (name from the parsed item where available, else "tool").
- `CompanionManager` publishes:

```swift
@Published private(set) var runStatus: LoreleiRunStatus = .idle
@Published private(set) var streamText: String = ""       // accumulated deltas for the CURRENT turn, cleared on turn start
@Published private(set) var currentActivity: String?      // last toolCallStarted name until its completion
```

  driven by: shortcut press -> `.listening`; release -> `.transcribing`; turn start (desktop/read-only/write/screen run begins) -> `.working("Thinking…")` + `streamText = ""`; progress deltas append to `streamText`; toolCallStarted -> `.working(name)` + `currentActivity = name`; approval request -> `.needsApproval(title)`, resolution returns to `.working`; run completion -> `.finished(success:)` then `.idle` after 4 seconds (Task-based delay, cancelled if a new run starts).

- [ ] **Step 1: Failing tests** (scripted-frame fixture patterns already in LoreleiTests):
- `executorReportsProgressForDeltasAndToolCalls` - drive a fake transport through initialize/thread/turn with two `item/agentMessage/delta` frames and one dynamic tool call; collect progress events; expect `[.agentMessageDelta("Hel"), .agentMessageDelta("lo"), .toolCallStarted(name: "lorelei.desktop_snapshot"), .toolCallCompleted(name: "lorelei.desktop_snapshot", success: true)]` (order-locked).
- `companionManagerTracksRunStatusThroughVoiceTurn` - injected app-server runner fixture: assert `.listening` on shortcut press, `.transcribing` on release, `.working` during the run, `.finished(success: true)` at completion, and `streamText` contains the accumulated delta text.
- `companionManagerShowsNeedsApprovalStatusDuringApprovalBridge` - reuse the approval fixture; while an approval is pending, `runStatus == .needsApproval(title)` and after `acceptPendingApproval()` it returns to `.working`.

- [ ] **Step 2: Red via build-for-testing, then implement.**

- [ ] **Step 3: Reviewer runs tests + commits** (`feat: add turn progress state model`).

---

### Task 2: Stop support

**Files:**
- Modify: `Lorelei/CodexAppServerExecutor.swift`, `Lorelei/CompanionManager.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- `CodexAppServerExecutor.init` gains `onTransportReady: @escaping @Sendable (CodexAppServerTransporting) -> Void = { _ in }`, called right after `makeTransport()` succeeds.
- `CompanionManager` stores the live transport (cleared when the run ends) and produces:

```swift
func stopCurrentRun()   // terminates the live transport, cancels currentResponseTask,
                        // cancels any pending approval, sets runStatus to .finished(success: false)
                        // and latestResultSummary to "Stopped."
```

- [ ] **Step 1: Failing tests:**
- `companionManagerStopTerminatesLiveTransport` - fixture transport records `terminate()`; start a run, call `stopCurrentRun()` mid-turn, expect terminate called, summary "Stopped.", status `.finished(success: false)`.
- `companionManagerStopWithoutRunIsNoOp` - `stopCurrentRun()` at idle changes nothing.

- [ ] **Step 2: Red, implement.** Note the executor already treats a dead transport as turn failure (timeout path) - stopping must not crash the read loop; `nextLine()` returning nil/throwing after terminate is the expected exit.

- [ ] **Step 3: Reviewer runs tests + commits** (`feat: add stop support for running turns`).

---

### Task 3: Floating glass toolbar window (collapsed state)

**Files:**
- Create: `Lorelei/LoreleiToolbarController.swift` (NSPanel management)
- Create: `Lorelei/LoreleiToolbarView.swift` (SwiftUI)
- Modify: `Lorelei/LoreleiApp.swift` / `Lorelei/CompanionManager.swift` (instantiate controller at launch)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**

```swift
@MainActor
final class LoreleiToolbarController {
    init(companionManager: CompanionManager)
    func show()                       // creates the panel on the active screen, top-center
    var isExpanded: Bool { get }
    func setExpanded(_ expanded: Bool)
    // Pure, testable layout helper:
    static func panelFrame(screenFrame: CGRect, size: CGSize, topInset: CGFloat) -> CGRect
}
```

- Panel: `NSPanel` with `.nonactivatingPanel`, `.fullSizeContentView`, borderless, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`, transparent background hosting the SwiftUI view. Positioned top-center of the screen with the mouse cursor, just below the menu bar (topInset 8). Always visible while the app runs (idle shows a slim quiet capsule).
- Collapsed view: horizontal glass capsule ~(220-280)x36: status dot (idle gray / listening green pulse / working blue / needsApproval orange / failed red), status text from `runStatus` (e.g. "Ready", "Listening…", "lorelei.set_text", "Needs approval"), and when `.working` a subtle progress shimmer. Clicking toggles expansion (Task 4 renders the expanded content; for this task expansion just enlarges the panel with a placeholder).
- Liquid glass: apply the macOS 26 glass APIs (`.glassEffect(...)` on the capsule; wrap groups in `GlassEffectContainer` if the SDK requires). Verify exact modifier names against the SDK headers; if a name differs, match the SDK - the tests do not assert rendering.

- [ ] **Step 1: Failing tests** (logic only):
- `toolbarPanelFrameCentersAtTopOfScreen` - `panelFrame(screenFrame: CGRect(x:0,y:0,width:2000,height:1200), size: CGSize(width:260,height:36), topInset: 8)` == `CGRect(x:870, y:1156, width:260, height:36)` (AppKit origin at bottom-left).
- `toolbarStatusLabelReflectsRunStatus` - a pure `LoreleiToolbarView.statusLabel(for:)` helper: `.idle`->"Ready", `.listening`->"Listening…", `.transcribing`->"Transcribing…", `.working("lorelei.set_text")`->"lorelei.set_text", `.needsApproval`->"Needs approval", `.finished(success:false)`->"Failed".

- [ ] **Step 2: Red, implement, build-for-testing.**

- [ ] **Step 3: Reviewer runs tests, launches the app to eyeball the capsule, commits** (`feat: add floating glass status toolbar`).

---

### Task 4: Expanded panel + menu bar reduction

**Files:**
- Modify: `Lorelei/LoreleiToolbarView.swift` (expanded content)
- Modify: `Lorelei/MenuBarPanelManager.swift` + `Lorelei/CompanionPanelView.swift` (reduce to settings/quit)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces & behavior:**
- Expanded toolbar (~460 wide, height fits content, same glass): 
  - header: status dot + label + close (collapse) button
  - stream area: `streamText` in a scroll view (auto-scrolls to bottom), monospaced-light, max height ~320; shows `latestResultSummary` when the turn is over
  - activity line: `currentActivity` with a spinner while `.working`
  - approval block (only when `.needsApproval`): title + Accept / Decline buttons calling `acceptPendingApproval()` / `cancelPendingApproval()`
  - footer: Stop button (visible during `.working`/`.needsApproval`) calling `stopCurrentRun()`
  - NO history, NO text input (spec decision #10)
- Expansion is also automatic: expand when `runStatus` becomes `.needsApproval` (the one state that demands attention); collapse manually otherwise.
- Menu bar item keeps only: workspace picker row, permissions status rows (read-only, with Grant buttons while missing), and Quit - i.e. CompanionPanelView loses the transcript/result/debug/pending-approval sections (those now live in the toolbar; the Debug log stays accessible in the settings popover behind a disclosure, since it is a developer aid).
- The old panel positioning bug (anchored under a possibly-hidden status item) becomes irrelevant for status, but for the settings popover add the fallback: if the status item button window is nil or offscreen, center the panel on the main screen.

- [ ] **Step 1: Failing tests:**
- `toolbarAutoExpandsOnApprovalRequest` - drive the approval fixture; expect `LoreleiToolbarController.isExpanded == true` after `runStatus` hits `.needsApproval` (controller observes the manager; test via the controller with a manager fixture, no panel needed - guard panel creation so it is lazy and skipped in tests if needed).
- `settingsPanelFrameFallsBackToScreenCenter` - pure helper on MenuBarPanelManager: given a nil/offscreen anchor frame, returns a centered rect for the given screen.

- [ ] **Step 2: Red, implement, build-for-testing.**

- [ ] **Step 3: Reviewer runs tests + commits** (`feat: move run UI into expanded toolbar, reduce menu bar panel`).

---

### Task 5: Full verification + live smoke + phase PR

- [ ] **Step 1: Reviewer: full suite including UI tests.**
- [ ] **Step 2: Live smoke:** launch the app; confirm (a) glass capsule visible top-center regardless of menu bar clutter, (b) hold Ctrl+Option -> "Listening…", release -> "Transcribing…" -> working states with live tool names, (c) click expands to live stream, (d) Stop button kills a run mid-flight with "Stopped.", (e) settings popover still reachable from the menu bar icon (or its fallback centering).
- [ ] **Step 3: Reviewer commits any smoke fixes, pushes `phase-4-glass-toolbar`, opens the phase PR referencing the spec and PRD #2, merges per delegation.**
