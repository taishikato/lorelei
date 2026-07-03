# Follow-up 2: Steer the Running Turn by Voice - Implementation Plan

> **For agentic workers:** Executed by Codex (gpt-5.5) task-by-task, reviewed by the planner. No git write commands from Codex; the reviewer stages/commits and runs tests. Codex verifies with:
> `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO build-for-testing`

**Goal:** Speaking while a turn is running injects the utterance into that turn (`turn/steer`) instead of starting a new one - "no, the other window" mid-run just works. Idle utterances start turns as today (approved decision C, 2026-07-03).

**Protocol facts (from docs/appserver-schema, codex-cli 0.142.4):** `turn/steer` params require `threadId`, `expectedTurnId` (fails when it does not match the active turn), and `input` (array of UserInput, same shape as turn/start input). The active turn id arrives in the `turn/started` server notification, which the executor currently ignores.

**Architecture:** The executor parses `turn/started` and reports the active turn through a new progress case; CompanionManager tracks `(threadID, turnID)` for the running turn alongside the live transport it already holds. `handleFinalTranscriptLocally` gains one branch at the top: if a turn is active (`runStatus` working/needsApproval and an active-turn record exists), send `turn/steer` over the live transport with a fresh request id and return - no routing, no task cancellation, no runStatus reset. A steer whose error response comes back (turn ended in the race window) is logged and the utterance falls back to a normal new turn.

## Global Constraints

- The steer path must NOT: cancel `currentResponseTask`, reset `streamText`/`runStatus`, resolve pending approvals, or play the run-finished cues. It plays no extra sound (the listening start/stop cues already bracket the utterance).
- A JSON-RPC error response whose id belongs to a steer request must not fail the running turn: it is recorded to the debug log and triggers the new-turn fallback for that utterance. Non-steer protocol behavior is unchanged.
- Request ids for steer come from the same per-connection monotonic counter (`CodexAppServerSessionStore.nextRequestID()`).
- Reviewer test command: `xcodebuild test ... -skip-testing:LoreleiUITests -test-timeouts-enabled YES -default-test-execution-time-allowance 60`, run 3x for concurrency changes. Commit messages in English.

---

### Task 1: Executor reports the active turn; protocol gains turn/steer

**Files:**
- Modify: `Lorelei/CodexAppServerProtocol.swift`, `Lorelei/CodexAppServerExecutor.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**

```swift
// CodexAppServerProtocol:
static func turnSteerRequest(id: Int, threadID: String, expectedTurnID: String, prompt: String) -> [String: Any]
// params: threadId, expectedTurnId, input: [["type": "text", "text": prompt]]
// (match the UserInput shape turnStartRequest already uses)

// parseInboundLine gains: case turnStarted(turnID: String)   // from the "turn/started" notification

// CodexAppServerTurnProgress gains:
case turnStarted(threadID: String, turnID: String)
case turnEnded
// .turnStarted fires when the read loop sees turn/started; .turnEnded fires when
// runDesktopAction returns (any path: completed, timeout, error, stop).
```

- [ ] **Step 1: Failing tests** (locked names):
- `appServerTurnSteerRequestEncodesActiveTurnPrecondition` - builder output has method "turn/steer", params.threadId/expectedTurnId, and input `[{type: text, text: prompt}]`.
- `appServerExecutorReportsTurnStartedAndEnded` - scripted transport whose frames include a `turn/started` notification (use the real shape: `{"method":"turn/started","params":{"threadId":"thread-1","turnId":"turn-9"}}`) before deltas; progress recorder sees `.turnStarted(threadID: "thread-1", turnID: "turn-9")` before the deltas and `.turnEnded` after completion.
- [ ] **Step 2: Red via build-for-testing, implement, build green.** (If the real `turn/started` notification nests ids differently, match the schema in docs/appserver-schema/ServerNotification.json and adjust the test fixture to the real shape - the schema is the contract.)
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: report active turn and add turn/steer request`).

---

### Task 2: CompanionManager steers mid-run utterances

**Files:**
- Modify: `Lorelei/CompanionManager.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Behavior:**
- Track `activeTurn: (threadID: String, turnID: String)?` from `.turnStarted`/`.turnEnded` progress events (cleared also by stop/reset paths).
- At the top of `handleFinalTranscriptLocally`: if `activeTurn != nil` and a live transport exists, send `turn/steer` (fresh id from the session store) with the raw transcript, record debug "Steered: <transcript>", and return without touching the running task/state. Note: today this method starts by cancelling `currentResponseTask` and the pending approval - the steer branch must run BEFORE those lines.
- Track outstanding steer request ids; when an error response for one arrives (surface it from the executor via a progress case or a dedicated callback - implementer's choice, report it), log "Steer failed - starting a new turn" and route the saved transcript through the normal path.
- Steer while `.needsApproval` is allowed (the model may use it once approval resolves); everything else about approvals is untouched.

- [ ] **Step 1: Failing tests** (locked names):
- `companionManagerSteersUtteranceIntoRunningTurn` - hanging-after-lines transport keeps a turn alive after `turn/started`; second `handleFinalTranscriptForTesting("actually the other window")` while working; assert a `turn/steer` line with expectedTurnId was sent, `currentResponseTask` kept running (runStatus still working, streamText not reset), and no second `turn/start` was sent.
- `companionManagerStartsNewTurnWhenIdle` - after the turn completes, the next utterance sends `turn/start` (not steer).
- [ ] **Step 2: Red, implement, build green.**
- [ ] **Step 3: Reviewer runs tests 3x + commits** (`feat: steer running turns with mid-run utterances`).

---

### Task 3: Full verification + live smoke + PR

- [ ] Reviewer: full suite incl. UI tests.
- [ ] Live smoke: start a slow task by voice (e.g. "open TextEdit and write a two-sentence story"), speak a correction mid-run ("make it about cats"); confirm the running turn absorbs it (stream reflects the correction, no restart), and an idle utterance still starts a fresh turn.
- [ ] Push `followup-turn-steer`, open PR, merge per delegation.

---

### Task 3 (added 2026-07-03 after user feedback): Interrupt keeps the session - context continuity

**Problem:** Stop and turn-timeout currently terminate the transport and invalidate the session, so the NEXT utterance starts a fresh thread with no memory ("it forgets which app we were talking about"). `thread/resume` cannot fix this (ThreadResumeParams has no dynamicTools, so resumed threads would lose the lorelei.* tools).

**Behavior:**
- `stopCurrentRun()`: when an active turn + live transport exist, send `turn/interrupt` (threadId, turnId) with a fresh request id and let the read loop finish naturally (the server ends the turn; treat a non-completed turn end as the existing "Stopped." result). The session survives - the next utterance reuses the thread with full context. Fallback to the old terminate+invalidate when there is no active turn/transport or the interrupt send throws.
- Turn timeout: send `turn/interrupt` first and give the server a 5-second grace window to end the turn; only if the read loop is still stuck after the grace window, terminate + invalidate as today. Timeout result message unchanged.
- Check docs/appserver-schema/ServerNotification.json for how interrupted turns end (turn/completed status value or a turn/aborted notification) and handle that shape in the read loop.

**Tests (locked names):**
- `companionManagerStopKeepsSessionForNextTurn` - stop mid-turn via interrupt; next utterance reuses the same transport (factory count 1) and sends turn/start on the SAME threadId.
- `appServerExecutorTimeoutInterruptsBeforeTerminating` - hanging turn; timeout path sends turn/interrupt; transport that then delivers the turn-end frame -> session survives; a transport that stays silent past the grace window -> terminated + invalidated as today.
