# Phase 5: Cursor Glass Capsule + Audio Feedback - Implementation Plan

> **For agentic workers:** Executed by Codex (gpt-5.5) task-by-task, reviewed by the planner. No git write commands from Codex; the reviewer stages/commits and runs tests. Codex verifies with:
> `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO build-for-testing`

**Goal:** While listening, a liquid-glass capsule with the live waveform floats next to the cursor (nothing else at the cursor); sound cues mark listening start/stop, completion, failure, and approval requests; completion/failure/approval get a one-sentence spoken summary.

**Architecture:** A `BuddyAudioFeedback` seam receives semantic events from CompanionManager at the exact sites that already drive `runStatus`; the default implementation plays system sounds and routes one-sentence text to the existing `SpeechOutputing`. The cursor overlay's listening state is restyled into a glass capsule; outside listening the cursor shows nothing new (processing feedback now lives in the phase 4 toolbar).

## Global Constraints

- Spec decisions #6 (capsule + waveform only at the cursor, no transcript) and #11 (sound cues + one-sentence TTS on completion/failure/approval).
- Element-pointing overlay (`detectedElementLocation` / CompanionResponseOverlay) is out of scope - do not touch.
- The phase 4 toolbar files are out of scope except where a call site must be updated.
- Sounds are macOS system sounds via `NSSound(named:)` - no bundled assets.
- Commit messages in English; reviewer test command: `xcodebuild test ... -skip-testing:LoreleiUITests`.

---

### Task 1: BuddyAudioFeedback seam + wiring

**Files:**
- Create: `Lorelei/BuddyAudioFeedback.swift`
- Modify: `Lorelei/CompanionManager.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**

```swift
enum BuddyAudioCue: Equatable, Sendable {
    case listeningStarted     // sound only (NSSound "Pop")
    case listeningEnded       // sound only ("Bottle")
    case runSucceeded         // sound ("Glass") + speech
    case runFailed            // sound ("Basso") + speech
    case approvalRequested    // sound ("Funk") + speech "Needs approval"
}

@MainActor
protocol BuddyAudioFeedbacking: AnyObject {
    func play(_ cue: BuddyAudioCue, spokenSummary: String?)
}

@MainActor
final class BuddyAudioFeedback: BuddyAudioFeedbacking {
    init(speechOutput: SpeechOutputing)
    // plays the system sound for the cue; if spokenSummary is non-nil,
    // speaks firstSentence(spokenSummary) after the cue
    static func firstSentence(_ text: String, maxCharacters: Int = 120) -> String
}
```

- CompanionManager gains `init` param `audioFeedback: BuddyAudioFeedbacking? = nil` (default: `BuddyAudioFeedback(speechOutput:)` built from the same speech output) and calls:
  - `.listeningStarted` where runStatus becomes `.listening`
  - `.listeningEnded` where it becomes `.transcribing`
  - `.runSucceeded` / `.runFailed` with `spokenSummary: result.summary` inside `finishRun(with:)` - REPLACING the existing `speechOutput.speak(result.spokenStatus)` calls for those paths (audit all call sites; unsupported-command failures also route through the feedback seam)
  - `.approvalRequested` (spokenSummary nil - the impl speaks the fixed phrase) where the approval bridge publishes `.needsApproval` - replacing any existing "Needs approval" speak call
- `firstSentence`: trim whitespace/newlines, cut at the first `。`, `.`, `!`, `?`, `！`, or `？` (keeping the terminator), then hard-cap at maxCharacters with `…`.

- [ ] **Step 1: Failing tests** (locked names):
- `firstSentenceCutsAtTerminatorAndCap` - `"Opened Gmail. Then waited."` -> `"Opened Gmail."`; a 300-char sentence -> 120 chars ending in `…`; Japanese `"Gmailを開きました。次に…"` -> `"Gmailを開きました。"`.
- `companionManagerPlaysCuesThroughVoiceTurn` - fake feedback recorder + the Task-1-phase-4 voice fixture: expect ordered cues `[.listeningStarted, .listeningEnded, .runSucceeded]` and the succeeded cue carries the run summary.
- `companionManagerPlaysFailureCueOnStop` - stop fixture: `.runFailed` with "Stopped." summary.
- `companionManagerPlaysApprovalCue` - approval fixture: `.approvalRequested` fired once while pending.
- [ ] **Step 2: Red (build-for-testing), implement, build green.**
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: add sound cues and one-sentence spoken summaries`).

---

### Task 2: Cursor glass capsule (listening only)

**Files:**
- Modify: `Lorelei/OverlayWindow.swift` (BlueCursorView listening presentation)
- Test: `LoreleiTests/LoreleiTests.swift`

**Behavior:**
- While `runStatus == .listening` (dictation active), the cursor companion renders a horizontal liquid-glass capsule (~140x34) to the RIGHT of the cursor position containing only the existing `BlueCursorWaveformView` (reuse it unchanged, driven by `currentAudioPowerLevel`).
- Outside listening, the phase-5 capsule is absent. The pre-existing triangle/spinner presentation for the element-pointing buddy cursor feature stays as is for its own states - only the LISTENING presentation is restyled into the capsule.
- Glass styling mirrors the toolbar: `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in:)` (match the spellings already used in `LoreleiToolbarView.swift`).
- Extract a pure helper for tests: `static func capsuleOrigin(cursorPoint: CGPoint, capsuleSize: CGSize, screenFrame: CGRect) -> CGPoint` - places the capsule 18pt right of the cursor, vertically centered on it, clamped inside `screenFrame` (so it flips to the LEFT of the cursor when the right edge would overflow).

- [ ] **Step 1: Failing tests** (locked names):
- `cursorCapsuleSitsRightOfCursor` - `capsuleOrigin(cursorPoint: (500,500), capsuleSize: (140,34), screenFrame: 0,0,2000x1200)` == `(518, 483)`.
- `cursorCapsuleFlipsLeftNearRightEdge` - cursor at `(1950, 500)` -> origin `(1950 - 18 - 140, 483)` == `(1792, 483)`.
- [ ] **Step 2: Red, implement, build green.**
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: restyle listening indicator as cursor-side glass capsule`).

---

### Task 3: Full verification + live smoke + phase PR

- [ ] Reviewer: full suite incl. UI tests.
- [ ] Live smoke: hold Ctrl+Option -> glass capsule with waveform next to the cursor + start cue; release -> end cue, capsule gone; completion -> chime + one-sentence spoken summary; failure/stop -> distinct sound; approval (if reproducible) -> sound + "Needs approval".
- [ ] Push `phase-5-cursor-capsule-audio`, open PR referencing spec + PRD #2, merge per delegation.
