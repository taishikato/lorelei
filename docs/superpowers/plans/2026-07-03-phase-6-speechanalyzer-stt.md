# Phase 6: SpeechAnalyzer STT Migration - Implementation Plan

> **For agentic workers:** Executed by Codex (gpt-5.5) task-by-task, reviewed by the planner. No git write commands from Codex; the reviewer stages/commits and runs tests. Codex verifies with:
> `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO build-for-testing`

**Goal:** Replace the SFSpeechRecognizer-based transcription with the macOS 26 SpeechAnalyzer family (`DictationTranscriber` + volatile/finalized results), fully on-device, behind the unchanged `BuddyTranscriptionProvider` / `BuddyStreamingTranscriptionSession` seam. Delete the old implementation (spec decision #9).

**Architecture:** A new `SpeechAnalyzerTranscriptionProvider` conforms to the existing protocol: `startStreamingSession` builds a `SpeechAnalyzer` with a `DictationTranscriber` module, feeds `appendAudioBuffer` input through the analyzer's input sequence (converting formats via the existing `BuddyAudioConversionSupport` if needed), maps volatile results to `onTranscriptUpdate` and finalized results to `onFinalTranscriptReady`, and finalizes on `requestFinalTranscript`. Model assets are ensured via `AssetInventory` on first use. Exact API spellings MUST be verified against the macOS 26 SDK - the WWDC25 names are `SpeechAnalyzer`, `DictationTranscriber`, `AssetInventory`, volatile/finalized result semantics; match the SDK, not this document, where they differ.

## Global Constraints

- Spec decision #9: `SpeechDetector` + `DictationTranscriber` era APIs only; delete `AppleSpeechTranscriptionProvider` (SFSpeechRecognizer) once the new provider is default.
- The `BuddyTranscriptionProvider` / `BuddyStreamingTranscriptionSession` protocols do NOT change; `BuddyDictationManager` and its tests keep working against fakes.
- Locale: prefer the same locale-resolution behavior the old provider had (preferred locales, fallback to system); if `DictationTranscriber` lacks keyterm support, drop keyterms silently (log once) - the protocol keeps the parameter.
- `requiresSpeechRecognitionPermission`: set to whatever the SDK actually requires for on-device SpeechAnalyzer dictation (verify; if no Speech authorization is needed, return false and check that the permission UI still renders correctly for mic-only).
- Reviewer test command: `xcodebuild test ... -skip-testing:LoreleiUITests`. Commit messages in English.

---

### Task 1: SpeechAnalyzerTranscriptionProvider

**Files:**
- Create: `Lorelei/SpeechAnalyzerTranscriptionProvider.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Produces `final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider` (displayName "Apple SpeechAnalyzer") and its session type.
- Produces a pure, tested transcript reducer that both the session and tests share:

```swift
struct SpeechAnalyzerTranscriptReducer: Equatable, Sendable {
    private(set) var finalizedText: String = ""
    private(set) var volatileText: String = ""
    /// Combined text shown while streaming: finalized + volatile remainder.
    var currentTranscript: String { get }
    mutating func applyVolatile(_ text: String)
    mutating func applyFinalized(_ text: String)   // appends to finalizedText (with a single separating space when non-empty), clears volatileText
}
```

- Session behavior: `appendAudioBuffer` forwards converted buffers into the analyzer input; every volatile result calls `onTranscriptUpdate(reducer.currentTranscript)`; `requestFinalTranscript()` finalizes the analyzer and delivers `onFinalTranscriptReady(reducer.currentTranscript)` exactly once (falling back after `finalTranscriptFallbackDelaySeconds` = keep the old provider's value if finalization stalls); `cancel()` tears down without delivering.
- Asset handling: on provider init or first session, check/install the transcriber assets via `AssetInventory`; while unavailable, `isConfigured == false` and `unavailableExplanation` explains the model is downloading.

- [ ] **Step 1: Failing tests** (locked names, pure - no audio hardware):
- `speechAnalyzerReducerCombinesVolatileAndFinalizedText` - volatile "hel" -> current "hel"; volatile "hello wor" -> "hello wor"; finalized "hello world" -> current == finalized == "hello world", volatile cleared; then volatile "again" -> current "hello world again".
- `speechAnalyzerReducerFinalizeIsIdempotentPerSegment` - two finalized segments "open textedit" + "type hello" -> finalizedText "open textedit type hello".
- [ ] **Step 2: Red (build-for-testing), implement provider + session + reducer, build green.** The analyzer/session code paths that need real audio are kept thin and obvious; only the reducer and option/locale resolution helpers need unit coverage.
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: add SpeechAnalyzer transcription provider`).

---

### Task 2: Make it the default and delete the SFSpeechRecognizer provider

**Files:**
- Modify: `Lorelei/BuddyTranscriptionProvider.swift` (factory returns the new provider; keep the `VoiceTranscriptionProvider` config key working with value "apple" mapping to the new provider)
- Delete: `Lorelei/AppleSpeechTranscriptionProvider.swift` (plain `rm`)
- Modify: any speech-recognition-permission plumbing that existed solely for SFSpeechRecognizer (check `requiresSpeechRecognitionPermission` consumers in `BuddyDictationManager`/`CompanionManager`/panel UI and align with what the new provider returns)
- Test: `LoreleiTests/LoreleiTests.swift`

- [ ] **Step 1: Update tests first** - factory/default-provider tests point at `SpeechAnalyzerTranscriptionProvider`; delete SFSpeech-specific tests if any.
- [ ] **Step 2: Implement; verify `grep -rn 'SFSpeech' Lorelei LoreleiTests` is empty (exit 1); build green.**
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: default to on-device SpeechAnalyzer transcription`).

---

### Task 3: Full verification + live smoke + phase PR

- [ ] Reviewer: full suite incl. UI tests.
- [ ] Live smoke: voice command end-to-end on the new STT (Japanese and English utterances); confirm transcript quality/latency in the toolbar, and that first-run model download (if triggered) surfaces the unavailableExplanation rather than a silent failure.
- [ ] Push `phase-6-speechanalyzer-stt`, open PR referencing spec + PRD #2, merge per delegation. Update the spec's phase table if all phases are now complete.
