# Follow-up 3: AX Battle-Testing - Implementation Plan

> **For agentic workers:** Executed by Codex (gpt-5.5) task-by-task, reviewed by the planner. No git write commands from Codex; the reviewer stages/commits and runs tests. Codex verifies with:
> `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO build-for-testing`

**Goal:** Exercise the lorelei.* desktop tools against real app archetypes (native AppKit, Electron, browser pages, menu-driven flows), collect failures, and fix the snapshot/prompt/foreground weaknesses they expose.

## Task 1: DEBUG text-command entry (URL scheme)

**Files:**
- Modify: `Lorelei/LoreleiApp.swift` (or a small new handler file), `Lorelei/Info.plist` (URL type), `Lorelei/CompanionManager.swift` (public entry)
- Test: `LoreleiTests/LoreleiTests.swift`

**Behavior:**
- Register the `lorelei` URL scheme (CFBundleURLTypes, name `dev.taishi.lorelei.debug`).
- DEBUG builds only (`#if DEBUG` around the handler): `lorelei://run?prompt=<percent-encoded>` feeds the decoded prompt into the exact same path as a final voice transcript (steer semantics included when a turn is active). Release builds ignore the URL entirely.
- The utterance appears in the conversation log like any voice command (no special marking needed).
- Pure helper for tests: `static func debugPrompt(fromURL url: URL) -> String?` - returns the decoded prompt for valid `lorelei://run?prompt=...` URLs, nil for anything else (wrong scheme/host/missing query).

**Tests (locked names):**
- `debugRunURLParsesPromptAndRejectsOthers` - valid URL with percent-encoded Japanese + spaces decodes correctly; `lorelei://other`, `https://run`, missing prompt -> nil.
- `companionManagerHandlesDebugPromptLikeTranscript` - feeding via the handler entry produces the same routing/log behavior as handleFinalTranscriptForTesting (reuse a scripted fixture; assert conversation log gains the user entry and a turn/start goes out).

## Task 2: Battle-test scenarios (manual, scripted via URL entry)

Reviewer-driven with the user observing; results recorded in `docs/battle-test-log.md` (created during the run):

| # | Archetype | Scenario (via lorelei://run) |
|---|-----------|------------------------------|
| 1 | Native AppKit | "Open Notes and create a new note titled Groceries with three items" |
| 2 | Native, menu-driven | "In TextEdit, make the current document's text bold using the Format menu" |
| 3 | System UI | "Open System Settings and tell me whether Bluetooth is on" |
| 4 | Browser DOM | "Open apple.com in Safari and click the link to the Mac page" |
| 5 | Browser form | "Search for 'liquid glass' on Google in Safari" |
| 6 | Electron | "Open Visual Studio Code (or Slack) and tell me which file/channel is active" (skip if not installed) |
| 7 | Finder | "In Finder, create a folder named LoreleiTest on the Desktop" |
| 8 | Read-back | "Read me the first paragraph of the frontmost window" |

Record per scenario: outcome (ok / partial / fail), which tool call failed or looped, whether lorelei.screenshot was used, notable snapshot-quality issues (from the Debug log / conversation history).

## Task 3: Fix batch

Turn the recorded failures into concrete fixes (likely candidates: snapshot element filter/caps, action vocabulary gaps - e.g. menu bar items may need AXPress on AXMenuBarItem paths, scroll support, prompt guidance tweaks). Scoped once the data exists; tests per fix; PR at the end of the branch.
