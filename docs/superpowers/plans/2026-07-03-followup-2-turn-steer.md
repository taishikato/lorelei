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

---

### Task 4 (added 2026-07-03 after user feedback): Conversation history in the expanded toolbar

**Problem:** The expanded panel shows only the current/latest assistant stream. The user wants to always see the whole exchange - their own utterances (including steers) and the assistant responses - to trust that context is preserved.

**Interfaces:**

```swift
struct ConversationEntry: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
}
// CompanionManager publishes:
@Published private(set) var conversationLog: [ConversationEntry] = []
```

**Behavior:**
- Append a `.user` entry for every accepted utterance: new-turn transcripts AND steered transcripts (steer entries prefixed "↪ " to show they joined the running turn). Unsupported/failed-route transcripts still appear as user entries followed by the failure text as an `.assistant` entry.
- During a turn, the streaming text updates the LAST `.assistant` entry in place (create it on first delta); on completion the entry ends up holding the final summary (existing streamText/latestResultSummary behavior is unchanged for the capsule).
- The log survives across turns while the app runs (session resets do NOT clear it - it is the user-facing record); cap at the most recent 200 entries.
- Expanded panel: replace the single-stream area with a scrolling conversation list (user entries right-aligned or prefixed "You:", assistant entries plain; monospaced-light for assistant, medium for user; auto-scroll to bottom on updates). Stop/approval/footer behavior unchanged.

**Tests (locked names):**
- `companionManagerLogsUserAndAssistantEntriesAcrossTurns` - two voice turns over one session: log ends `[user, assistant, user, assistant]` with the right texts.
- `companionManagerLogsSteeredUtteranceIntoConversation` - steer mid-turn: a `.user` entry with the "↪ " prefix appears while the same assistant entry keeps streaming (no new assistant entry created by the steer).

---

### Task 5 (added 2026-07-03 after context-loss diagnosis): One thread for every Codex action

**Problem:** Only `.codexDesktopAction` runs on the app-server thread. `.codexReadOnly` / `.codexWorkspaceWrite` / `.codexScreen` still go through the stateless `codex exec` CLI path, so utterances like "Continue" (router default = readOnly) land in a separate brain with no conversation history. Protocol-level probe confirmed the thread itself shares context perfectly across turns.

**Schema facts (docs/appserver-schema):** `TurnStartParams` supports `sandboxPolicy` (SandboxMode: "read-only" | "workspace-write" | "danger-full-access") and `input` items of type `text` / `localImage` (path-based) among others.

**Behavior:**
- `CodexAppServerExecutor` generalizes `runDesktopAction` into `runTurn(prompt:cwd:sandboxPolicy:extraInput:)` (desktop actions keep today's parameters; `runDesktopAction` may remain as a thin wrapper). `turnStartRequest` gains optional `sandboxPolicy` and image input items (`{"type":"localImage","path":...}` appended after the text item).
- CompanionManager routes ALL Codex actions through the shared executor/session:
  - `.codexReadOnly` -> `runTurn(prompt, sandboxPolicy: "read-only")` (raw prompt, no desktop wrapper)
  - `.codexWorkspaceWrite` -> `runTurn(CodexPromptBuilder.workspaceWritePrompt(for:), sandboxPolicy: "workspace-write")`
  - `.codexScreen` -> capture screenshots as today, then `runTurn(prompt, sandboxPolicy: "read-only", extraInput: [localImage paths])` - replacing CodexScreenContextRequestRunner's exec invocation
  - `.codexDesktopAction` -> unchanged wrapper/parameters
  All four now stream progress, appear in the conversation log, steer, and share one thread.
- Retire the `codex exec` execution path: delete `CodexExecutionMode`, `CodexExecutor.run(...)` and its argument builder; KEEP `CodexExecutableLocator` and `CodexExecutor.makeLaunchCommand` (the app-server launch depends on them - rehome them if that reads better). Update WorkspaceCommandExecutor's placeholder arms and any tests referencing the exec path.
- `grep -rn 'CodexExecutionMode\|--output-last-message\|ask-for-approval' Lorelei LoreleiTests` must be empty afterward (exit 1).

**Tests (locked names):**
- `appServerTurnStartRequestEncodesSandboxPolicyAndLocalImage` - builder with sandboxPolicy "read-only" and one localImage path emits params.sandboxPolicy and input [text, localImage] per schema.
- `companionManagerRunsReadOnlyUtteranceOnSharedThread` - a desktop turn then "what did you just do" (routes readOnly) over ONE scripted transport: factory count 1, second turn/start carries sandboxPolicy "read-only" and the same threadId.
- `companionManagerRunsWorkspaceWriteOnSharedThread` - mutating utterance sends turn/start with sandboxPolicy "workspace-write" and the workspace-write wrapper prompt on the same thread.
- Screen path: adapt the existing screen-request tests to assert the shared executor receives the localImage input instead of a codex exec invocation.
