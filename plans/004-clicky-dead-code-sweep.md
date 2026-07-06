# Plan 004: Remove the dead clicky-era code (fly-to-element state, Claude model selection, response overlay, unused design tokens)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- Lorelei/CompanionManager.swift Lorelei/CompanionResponseOverlay.swift Lorelei/DesignSystem.swift Lorelei/OverlayWindow.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (plan 001's CI strengthens verification if merged)
- **Category**: tech-debt
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

Lorelei was forked from the "clicky" project and rewritten around Codex. Four
clusters of clicky-era code survive with zero live readers: a "fly to detected
element" animation state that no view observes, a Claude model selection in a
Codex-only app, an entire alternate overlay implementation that is never
instantiated, and unused design-system tokens. They sit in the app's
most-churned files and actively mislead (doc comments describe parsing
"Claude's response" - a pipeline that no longer exists). All were verified
dead by grep before this plan was written; each step re-verifies before
deleting.

## Current state

All references verified at commit `120103a`:

1. **Fly-to-element state** - `Lorelei/CompanionManager.swift:117-126`:

```swift
/// Screen location (global AppKit coords) of a detected UI element the
/// buddy should fly to and point at. Parsed from Claude's response;
/// observed by BlueCursorView to trigger the flight animation.
@Published var detectedElementScreenLocation: CGPoint?
/// The display frame (global AppKit coords) of the screen the detected
/// element is on, so BlueCursorView knows which screen overlay should animate.
@Published var detectedElementDisplayFrame: CGRect?
/// Custom speech bubble text for the pointing animation. When set,
/// BlueCursorView uses this instead of a random pointer phrase.
@Published var detectedElementBubbleText: String?
```

   The ONLY other references: `clearDetectedElementLocation()` definition at
   `CompanionManager.swift:208-212` (sets all three to nil) and its two call
   sites at `CompanionManager.swift:414` and `:866`. `BlueCursorView`
   (`Lorelei/OverlayWindow.swift`) reads only `currentAudioPowerLevel` and
   `runStatus` - the doc comments lie.

2. **Claude model selection** - `Lorelei/CompanionManager.swift:171` and
   `:194-196`:

```swift
@Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"
...
func setSelectedModel(_ model: String) {
    selectedModel = model
    UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
}
```

   No reader anywhere (`grep -rn "selectedModel\|setSelectedModel" Lorelei/ LoreleiTests/`
   returns only these lines). The Codex model is pinned separately in
   `CodexAppServerProtocol.swift` (`turnModel`) - unrelated, do not touch.

3. **`Lorelei/CompanionResponseOverlay.swift`** - whole file (a cursor-following
   response overlay). `grep -rln "CompanionResponseOverlay" Lorelei/ LoreleiTests/`
   matches only the file itself. The live overlay is `OverlayWindow.swift`.

4. **Unused DesignSystem tokens** - `Lorelei/DesignSystem.swift` (880 lines,
   65 static members; ~23 used project-wide). Candidates verified
   single-reference (definition only): `floatingGradientOrange`,
   `floatingGradientPink`, `floatingGradientPurple`, `helpChatBackdrop`,
   `helpChatUserBubble`, `waveformGlowColor`, `waveformLeadingColor`,
   `codeText`, `dragged`, `info`, `disabledText`. This list is from the audit -
   step 4 REQUIRES re-verifying each token individually before deleting it.

Repo conventions: comments only for non-obvious constraints; the Xcode project
uses filesystem-synced groups, so DELETING a file from disk removes it from
the build - no pbxproj edit needed.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Reference check | `grep -rn "<symbol>" Lorelei/ LoreleiTests/ LoreleiUITests/` | only the expected lines |
| Build | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData test -test-timeouts-enabled YES -default-test-execution-time-allowance 60` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `Lorelei/CompanionManager.swift` (deletions only, the exact members above)
- `Lorelei/CompanionResponseOverlay.swift` (delete file)
- `Lorelei/DesignSystem.swift` (delete verified-unused tokens only)

**Out of scope** (do NOT touch - all verified LIVE):
- `Lorelei/CodexExecutor.swift` (used by `CodexAppServerExecutor.swift:103`)
- `Lorelei/CompanionScreenCaptureUtility.swift` (used by
  `AXDesktopActionExecutor.swift:245`, `CompanionManager.swift:1097`)
- `Lorelei/WindowPositionManager.swift` (permission helpers used in 3+ files)
- `Lorelei/OverlayWindow.swift` (live overlay; you only READ it to verify)
- `CodexAppServerProtocol.swift` `turnModel` (the real, live model pin)
- The `"selectedClaudeModel"` UserDefaults entry on user machines (leave
  orphaned; no migration/removeObject code - harmless)

## Git workflow

- Branch: `clicky-dead-code-sweep`
- Commit style: `chore: remove dead clicky-era code` (one commit per step is
  fine: `chore: remove dead fly-to-element state`, etc.)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Remove the fly-to-element state

Re-verify: `grep -rn "detectedElement" Lorelei/ LoreleiTests/` → matches only
`CompanionManager.swift` lines ~117-126, 208-212, 414, 866. Then delete: the
three `@Published` properties with their doc comments, the
`clearDetectedElementLocation()` function, and its two call sites (the bare
`clearDetectedElementLocation()` lines at :414 and :866 - remove just those
statements, and at :414 keep the surrounding comment about not cancelling the
response task intact).

**Verify**: `grep -rn "detectedElement\|clearDetectedElementLocation" Lorelei/ LoreleiTests/` → no matches; build → `** BUILD SUCCEEDED **`.

### Step 2: Remove the Claude model selection

Re-verify: `grep -rn "selectedModel\|selectedClaudeModel" Lorelei/ LoreleiTests/`
→ only `CompanionManager.swift:171,194-196`. Delete the property and
`setSelectedModel`.

**Verify**: same grep → no matches; build succeeds.

### Step 3: Delete CompanionResponseOverlay.swift

Re-verify: `grep -rln "CompanionResponseOverlay" Lorelei/ LoreleiTests/ LoreleiUITests/`
→ only the file itself. Also grep for every top-level type name declared IN
that file (open it, list its `struct`/`class`/`enum` declarations, grep each)
- if any type is referenced elsewhere, STOP. Then `rm Lorelei/CompanionResponseOverlay.swift`.

**Verify**: build → `** BUILD SUCCEEDED **` (filesystem-synced groups pick up the deletion).

### Step 4: Prune unused DesignSystem tokens (verify each individually)

For EACH candidate token listed in Current state item 4: run
`grep -rn "<tokenName>" Lorelei/ LoreleiTests/ LoreleiUITests/`. Delete the
token ONLY if the sole match is its own definition in `DesignSystem.swift`.
If any candidate has a second reference, leave it and note it in your report.
Do not hunt for additional unused tokens beyond the listed candidates (keeps
this step bounded).

**Verify**: build → `** BUILD SUCCEEDED **`.

### Step 5: Full suite

**Verify**: test command → `** TEST SUCCEEDED **`.

## Test plan

No new tests - this plan only deletes unreferenced code; the full suite
passing (plus the per-step greps proving zero references) is the safety net.

## Done criteria

- [ ] All step greps return no matches for deleted symbols
- [ ] `Lorelei/CompanionResponseOverlay.swift` no longer exists
- [ ] Build and full test suite pass
- [ ] `git diff --stat` touches only the three in-scope files (one deleted)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any pre-deletion grep finds a reference the plan says should not exist
  (drift: someone wired the feature back up). Report the reference.
- A type declared in `CompanionResponseOverlay.swift` is referenced elsewhere.
- The build fails after a deletion and the error is NOT a trivially missing
  reference you just removed (e.g. an extension in another file) - report
  rather than chasing it.

## Maintenance notes

- If a "point at a UI element" feature is ever wanted again, it should be
  rebuilt against the current AX pipeline (`AXDesktopActionExecutor`
  element frames), not by resurrecting this state.
- Model selection, if wanted, belongs in settings wired to
  `CodexAppServerProtocol.turnModel` (see the audit's DIRECTION-03 note) -
  the deleted `selectedModel` was never connected to anything.
- Deferred deliberately: a full unused-symbol sweep of the remaining ~54
  DesignSystem members (audit confidence was MED beyond the listed 11).
