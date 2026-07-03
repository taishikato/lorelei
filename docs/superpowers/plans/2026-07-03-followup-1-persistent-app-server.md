# Follow-up 1: Persistent App Server Session - Implementation Plan

> **For agentic workers:** Executed by Codex (gpt-5.5) task-by-task, reviewed by the planner. No git write commands from Codex; the reviewer stages/commits and runs tests. Codex verifies with:
> `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO build-for-testing`

**Goal:** Kill the per-utterance cold start. Today every voice command spawns `codex app-server`, runs initialize + thread/start + turn/start, and terminates the transport on every exit path. After this change, one subprocess and one thread persist across turns; each utterance is just a `turn/start` on the live session.

**Architecture:** A new `CodexAppServerSessionStore` actor owns the live connection (transport, threadID, monotonic request-id counter, session cwd). `CodexAppServerExecutor.runDesktopAction` asks the store to `ensureSession(cwd:)` (spawn + initialize + `thread/start` only when there is no live session or the cwd changed), then runs its turn with the next request id and - on success or turn failure - LEAVES the transport alive. The transport is terminated only on: stop, turn timeout, transport-level errors, or cwd change. A turn that fails to even send (dead subprocess between turns) invalidates the session and retries once on a fresh one.

## Global Constraints

- Turn behavior (streaming, progress, approvals, dynamic tools, timeout message shape) is unchanged from the caller's perspective; `WorkspaceCommandResult` outputs stay the same.
- Dynamic tools are registered at `thread/start`, so they persist with the session; the specs resolver is captured when the session starts.
- Stop semantics stay instant: `stopCurrentRun()` terminates the live transport AND invalidates the session (next utterance pays one respawn - acceptable).
- Request ids: monotonic per session (first session: 1=initialize, 2=thread/start, 3=first turn/start, 4=second turn/start, ...). Update any test that hardcodes ids accordingly.
- Existing scripted single-turn tests must keep passing with at most id/termination-expectation updates (the executor no longer calls `terminate()` after `turn/completed`).
- Reviewer test command: `xcodebuild test ... -skip-testing:LoreleiUITests`. Commit messages in English.

---

### Task 1: Session store + executor reuse

**Files:**
- Modify: `Lorelei/CodexAppServerExecutor.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**

```swift
actor CodexAppServerSessionStore {
    struct LiveSession {
        let transport: CodexAppServerTransporting
        let threadID: String
        // next request id to hand out; ensureSession/turn code advances it
    }
    init(makeTransport: @escaping () async throws -> CodexAppServerTransporting)
    /// Returns the live session, creating one (spawn + initialize + initialized + thread/start,
    /// with the given dynamicTools and cwd) when none exists or when cwd differs from the
    /// session's cwd (the old session is terminated first).
    func ensureSession(
        cwd: String,
        dynamicTools: [CodexAppServerDynamicToolSpec],
        sendLine: ... // shaped to fit the existing send/trace helpers; design freedom here
    ) async throws -> LiveSession
    func nextRequestID() -> Int
    /// Terminates the transport (if any) and clears state.
    func invalidate() async
    var hasLiveSession: Bool { get }
}
```

Design freedom: the exact split of who performs initialize/thread-start IO (store vs executor helper) is the implementer's choice as long as the store owns lifecycle + ids and the executor owns turn orchestration, tracing, progress, approvals. `CodexAppServerExecutor` becomes a `final class` (or keeps struct shape holding the store reference) constructed ONCE per CompanionManager with the store injected; `onTransportReady` now fires whenever a NEW session's transport is created.

Behavior changes in `runDesktopAction`:
- No `terminate()` after `turn/completed` (success or tool-failure result) - the session lives on.
- Timeout path and transport read/send errors: terminate + `invalidate()` (unchanged user-visible message).
- Dead-session retry: if the FIRST send of a turn throws, or `nextLine()` returns nil before any turn event arrives, invalidate and retry the whole turn once on a fresh session; a second failure returns the normal failure result.
- Read-loop: events are only consumed during a turn, as today; stale between-turn lines (rare) are tolerated by the existing parser's ignore paths.

- [ ] **Step 1: Failing tests** (locked names; reuse the scripted `FakeCodexAppServerTransport` patterns):
- `appServerSessionReusesTransportAcrossTurns` - one scripted transport containing initialize/thread frames + TWO complete turns' frames; run `runDesktopAction` twice on one executor; expect: single transport creation (factory call count 1), second turn's `turn/start` uses request id 4, no `terminate()` recorded between turns, both results succeed.
- `appServerSessionRespawnsWhenCwdChanges` - two runs with different `cwd`; factory called twice, first transport terminated, second run's `thread/start` carries the new cwd.
- `appServerSessionRetriesOnceOnDeadTransport` - first transport's `send` throws (or returns nil immediately); factory yields a healthy second transport; the turn succeeds and factory call count is 2.
- `appServerStopInvalidatesSession` - after a stopped turn (existing stop fixture), the next run creates a fresh transport (factory count 2).
- [ ] **Step 2: Red via build-for-testing, implement, update existing tests whose id/termination expectations changed (report which), build green.**
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: persist app server session across turns`).

---

### Task 2: CompanionManager holds one executor

**Files:**
- Modify: `Lorelei/CompanionManager.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Behavior:**
- The desktop-action executor (and its session store) is created once per CompanionManager (lazily on first use is fine) instead of per run; the injected `codexAppServerTransportFactory` and injected runner fixtures keep working (factory now called once per SESSION, not per run).
- `stopCurrentRun()` additionally invalidates the session store (transport terminate alone is no longer enough).
- Workspace path changes flow through `ensureSession(cwd:)` naturally - no extra CompanionManager logic beyond passing the current cwd per turn.
- Debug log gains one line per session lifecycle: "App Server: session started" / "App Server: session reused" / "App Server: session reset" so latency behavior is observable in the panel.

- [ ] **Step 1: Failing test** (locked name):
- `companionManagerReusesAppServerSessionAcrossVoiceTurns` - drive two voice turns through the injected transport factory (scripted with two turns); factory called once; both `latestResultSummary` updates arrive.
- [ ] **Step 2: Red, implement, build green.**
- [ ] **Step 3: Reviewer runs tests + commits** (`feat: reuse app server session in companion manager`).

---

### Task 3: Full verification + live smoke + PR

- [ ] Reviewer: full suite incl. UI tests.
- [ ] Live smoke: two consecutive voice commands; confirm the second one starts visibly faster (no respawn), debug log shows "session reused", Stop still kills instantly and the following command works (respawn), and changing the workspace picks up the new cwd.
- [ ] Push `followup-persistent-app-server`, open PR referencing the spec + PRD #2, merge per delegation.
