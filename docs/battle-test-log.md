# Battle-Test Log (2026-07-03)

Environment: macOS 26.5, codex-cli 0.142.4, gpt-5.5, Lorelei followup-battle-testing branch.
Commands injected via `lorelei://run` debug scheme; user observes outcomes.

| # | Archetype | Prompt | Outcome | Notes |
|---|-----------|--------|---------|-------|
| 1 | Native AppKit (Notes) | Open Notes and create a new note titled Groceries with three items | FAIL (partial) | Notes opened, but the model clicked the NEW FOLDER button instead of New Note - left a "Quick Notes" folder in rename mode; no Groceries note created. Hypothesis: AX snapshot does not disambiguate the two toolbar buttons (both likely AXButton with sparse titles); model guessed wrong. |
| 1b | (correction) | - | TIMEOUT | Turn hit the 120s timeout mid-recovery, leaving the folder-rename state. Root finding from the preceding TextEdit turn's narrative: lorelei.foreground_app FAILS to launch/activate apps in practice ("前面化APIからは起動できていません" for both Finder and TextEdit); the model recovered via Apple menu > Recent Items. Foreground failures waste most of the turn budget. |
| 1r | Notes retry (post-fix) | same | FAIL (confounded) | Leftover folder-rename edit state from run 1 was still active and likely hijacked the retry; no Groceries note. Needs a clean-state rerun. |
| 2 | Menu-driven (TextEdit) | In TextEdit, make the current document's text bold using the Format menu | PASS | Text selected and Bold applied (font panel shows Bold, B toggle active). Menu-bar interaction works. |
| 1r2 | Notes retry analysis | - | TIMEOUT (interrupted) | Trace tail is all agentMessageDelta (no tool calls) - model streamed deliberation until the 300s timeout; timeout's turn/interrupt ended the turn as interrupted and the session/context survived (verified: next TextEdit turn ran on the same thread). Hypothesis: Notes' 130-note sidebar makes snapshots huge (near the 400-element cap), slowing every look. |
| 1r3 | Notes attempt 3 (clean state) | same | FAIL (diagnosed) | Model's own narrative pinpointed: (a) depth-first 400-element snapshot cap starves the toolbar/menu bar out of the tree ("新規ノートボタンとメニューバーが省略され"); (b) activation raises the window but the ACTIVE app / menu bar ownership stays elsewhere; (c) AXPress rejected on folder/note rows (rows want AXOpen/selection). |
| 1r4 | Notes attempt 4 (post batch 2) | same | PARTIAL | Frontmosting fixed (first try) and menu-driven New Note SUCCEEDED. New blockers: focused text area truncated out of snapshot (6x set_text failures on unavailable IDs); open-menu AXMenuItem flood ate the budget; model then burned minutes on shell/AppleScript dead ends (no Automation permission). Fix batch 3: focused-element guarantee + elementId "focused", menu subtree quota, prompt guidance against script escalation. |
| 1r5 | Notes attempt 5 (post batch 3) | same | PASS | Groceries note with Milk/Eggs/Bread created in under a minute. Cumulative fixes: AX frontmosting, prioritized snapshot budget, row actions, focused-element guarantee. |
| 3 | System UI | Open System Settings and tell me whether Bluetooth is on | PASS | Correctly answered ON (verified against the visible toggle). Sidebar navigation via desktop_action open. |
| 4 | Browser (Safari) | Open apple.com in Safari and click the link to the Mac page | FAIL (blocked, clean) | URL open succeeded (apple.com loaded) but foreground_app activation verification failed repeatedly (Safari cold launch - verification window too short?). Model correctly refused script escalation and reported the blocker. |
| 4r | Safari retry (post batch 4) | same | INCONCLUSIVE | Ran while the lid was closed / machine slept mid-turn (user confirmed); external display disconnected, Safari left windowless. Dock-click shows a window fine. Retest Safari scenarios in a stable session before drawing conclusions. |
| 7 | Finder | In Finder, create a folder named LoreleiTest on the Desktop | PASS | Folder verified on the filesystem (~2 min, AX-driven Finder navigation). |
| 8 | Read-back | Read me the first paragraph of the frontmost window | PASS | Correctly identified Finder's Desktop window and reported there is no readable paragraph (accurate). Exposed and fixed a real bug: Japanese summaries were never SPOKEN (default AVSpeech voice silently skips other scripts) - language-aware voice selection added, spoken output confirmed. |

## Deferred
- 5 (Safari Google search) and 4 retest: rerun in a stable session (row 4r was confounded by lid-close/sleep).
- 6 (Electron): not run this session.

## Fix batches landed during the sweep
1. Cooperative-activation-safe foregrounding, 300s turn timeout, snapshot AX hints
2. Prioritized snapshot budget (menu bar/chrome first, per-container row quotas), AX kAXFrontmostAttribute frontmosting with verification, row actions (open/select/showMenu)
3. Focused-element guarantee + elementId "focused", menu subtree quotas, no-script-escalation prompt guidance
4. Cold-launch-aware activation (isFinishedLaunching wait, 8s backoff verification)
5. Language-aware TTS voice selection
