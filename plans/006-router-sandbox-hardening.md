# Plan 006: Make voice routing conservative - questions never escalate, desktop turns get an explicit readOnly sandbox

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- Lorelei/LoreleiCommandRouter.swift Lorelei/CodexAppServerExecutor.swift LoreleiTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1 (security)
- **Effort**: M
- **Risk**: MED - this deliberately changes routing behavior; the test matrix
  below is the contract
- **Depends on**: none (CI from plan 001 strongly recommended first)
- **Category**: security
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

The router classifies raw speech with bare keyword matching. Any utterance
containing one common verb ("add", "update", "search", "open", "ask") routes
to a higher-capability path: `workspaceWrite` (Codex may modify files in the
workspace without further prompts - in-sandbox writes are what that sandbox
auto-permits) or desktop control. A question - "should I **add** error
handling here?" - becomes a file-mutating turn. Separately, desktop-action
turns are started with NO sandboxPolicy at all (server default), the loosest
of the three paths.

The product decision "no confirmation dialog before commands" stands and is
not changed here. The fix is that ambiguous input must land on the LEAST
capable path (readOnly), and escalation to writes then flows through the
existing Codex approval bridge (the toolbar's Accept/Decline), which is the
designed safety valve.

## Current state

- `Lorelei/LoreleiCommandRouter.swift` (207 lines) - the whole router. Routing
  order in `route(_:)` (lines 82-118): screen → computerUse → status → diff →
  tests → mutating → readOnly fallback. The two escalating classifiers:

```swift
// lines 140-162
private func isMutatingRequest(_ command: String) -> Bool {
    containsAnyWord(in: command, words: [
        "fix", "edit", "write", "create", "delete", "change", "refactor",
        "install", "update", "add", "remove", "rename", "move", "modify",
        "apply", "implement", "replace", "configure", "setup"
    ]) || command.contains("set up")
}

// lines 164-187
private func isComputerUseRequest(_ command: String) -> Bool {
    command.contains("click")
        || command.contains("open app")
        || command.contains("open the app")
        || command.contains("open browser")
        || command.contains("open the browser")
        || command.contains("launch")
        || command.contains("computer use")
        || command.contains("system settings")
        || command.contains("use the browser")
        || containsAnyWord(in: command, words: [
            "browser", "open", "launch", "type", "search", "ask",
            "enter", "submit", "press", "click", "scroll"
        ])
}
```

  `containsAnyWord` (lines 199-205) tokenizes on non-alphanumerics and checks
  membership anywhere in the utterance. `route` lowercases and trims first.

- `Lorelei/CompanionManager.swift:626-630` area: `.codexWorkspaceWrite` runs
  `runCodexAppServerTurn(prompt:sandboxPolicy: "workspaceWrite")`;
  `.codexReadOnly` uses `"readOnly"`. `.codexDesktopAction` goes through
  `runCodexAppServerDesktopAction` (line ~723) →
  `executor.runDesktopAction(prompt:cwd:)`.
- `Lorelei/CodexAppServerExecutor.swift:444`:
  `func runDesktopAction(prompt: String, cwd: String) async -> WorkspaceCommandResult`
  - it forwards into the internal run path whose `sandboxPolicy: String? = nil`
  default (line 400) means `turnStartRequest` OMITS the field entirely
  (`CodexAppServerProtocol.swift`: `if let sandboxPolicy { params["sandboxPolicy"] = ["type": sandboxPolicy] }`).
- Existing router tests: `LoreleiTests/LoreleiTests.swift:676-750` -
  `@Test func routerMapsShowGitStatusToStatus()` etc. Pattern:
  `let router = LoreleiCommandRouter(); #expect(router.route("...") == .gitStatus)`.
  Use these as the structural pattern; some may need updating per the matrix
  below (that is expected and in scope).
- Transport fakes in tests expose `sentJSONMessages()` returning
  `[[String: Any]]` of every JSON line the executor wrote - use it to assert
  the turn/start payload (exemplar: `appServerExecutorTimeoutInterruptsBeforeTerminating`
  around `LoreleiTests.swift:2700+`).
- Approval bridge (context, do not modify): Codex-initiated approval requests
  surface as toolbar Accept/Decline via `CompanionManager.requestCodexAppServerApproval`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData test -test-timeouts-enabled YES -default-test-execution-time-allowance 60` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `Lorelei/LoreleiCommandRouter.swift`
- `Lorelei/CodexAppServerExecutor.swift` - ONLY the `runDesktopAction` sandbox
  argument
- `LoreleiTests/LoreleiTests.swift` - router tests + one executor payload test

**Out of scope** (do NOT touch):
- The approval flow, `CompanionManager` routing switch, prompts in
  `CodexPromptBuilder`, analytics.
- Adding any confirmation dialog (explicitly against a recorded product
  decision).
- The `workspaceWrite` sandbox itself for explicit imperatives - "fix the
  tests" must still route to workspaceWrite.

## Git workflow

- Branch: `router-sandbox-hardening`
- Commit style: `fix: route ambiguous speech read-only and pin desktop turns to a readOnly sandbox`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Pin desktop-action turns to an explicit readOnly sandbox

In `CodexAppServerExecutor.swift`, make `runDesktopAction` pass
`sandboxPolicy: "readOnly"` into the internal run path it already calls
(read the function body at line ~444 first; it forwards to the same
private run/`attemptTurn` machinery `runTurn` uses - thread the string
through the existing parameter, do not add new plumbing). Desktop control
itself is unaffected: the `lorelei.*` desktop tools execute inside the
Lorelei app, not inside Codex's sandbox; the sandbox only constrains Codex's
own shell/file access, and shell writes now surface through the approval
bridge instead of being silently permitted by an unspecified policy.

Add a unit test (pattern: existing executor tests with
`FakeCodexAppServerTransport` + `sentJSONMessages()`): call
`executor.runDesktopAction(...)` against a scripted transport, find the
message with `"method" == "turn/start"`, assert
`params.sandboxPolicy.type == "readOnly"` (navigate the `[String: Any]`).

**Verify**: build + the new test passes.

### Step 2: Add normalization and a question guard to the router

In `LoreleiCommandRouter.swift`:

1. Normalize before classification (new private helper): from the lowercased
   trimmed command, iteratively strip these leading politeness prefixes:
   `"please "`, `"hey lorelei "`, `"lorelei "`, `"hey "`, `"can you "`,
   `"could you "`, `"would you "`. ("can you open safari" → "open safari".)
2. Question guard: after the `isScreenRequest` check (screen questions like
   "what's on my screen" must keep working - screen stays FIRST), if the
   normalized command's first token is one of
   `what, why, how, when, where, who, whose, which, should, shall, would,
   could, can, do, does, did, is, are, was, were, am, will` → return
   `.codexReadOnly(originalCommand)` immediately. (Politeness stripping ran
   first, so "can you ..." forms were already de-questioned.)
3. Leading-token gate for BARE-WORD escalation: change the
   `containsAnyWord(...)` calls in `isMutatingRequest` and
   `isComputerUseRequest` to a new
   `matchesWord(in:words:withinLeadingTokens: 4)` that only matches when the
   word appears among the first 4 tokens of the normalized command. The
   PHRASE checks in `isComputerUseRequest` (`contains("click")`,
   `contains("open the browser")`, `contains("system settings")`, etc.) stay
   position-independent and unchanged. `isStatusRequest`/`isDiffRequest`/
   `isRunTestsRequest` are unchanged.

Route order becomes: screen → question-guard → computerUse → status → diff →
tests → mutating → readOnly.

**Verify**: build succeeds.

### Step 3: Encode the contract as tests

Add router tests following the existing pattern at
`LoreleiTests.swift:676-750`. The matrix (every row is one `#expect`):

| Utterance | Expected |
|---|---|
| `"should I add error handling here?"` | `.codexReadOnly` |
| `"what would you add to this file?"` | `.codexReadOnly` |
| `"can you search the git history for the bug?"` | `.codexReadOnly` (politeness-stripped, "search" not in first 4 tokens? it IS token 1 after strip → desktopAction... see note below) |
| `"open textedit and write a story"` | `.codexDesktopAction` |
| `"can you open textedit"` | `.codexDesktopAction` (politeness stripped → leading "open") |
| `"please fix the failing test"` | `.codexWorkspaceWrite` |
| `"fix the login bug"` | `.codexWorkspaceWrite` |
| `"tell me about the codebase and how files are added"` | `.codexReadOnly` ("added"/"add" beyond token 4) |
| `"what's on my screen?"` | `.codexScreen` (screen check precedes question guard) |
| `"what changed?"` | `.gitDiff` (question guard must NOT shadow it - see note) |
| `"is it safe to delete the cache?"` | `.codexReadOnly` |
| `"update the readme with the new install steps"` | `.codexWorkspaceWrite` |

Two rows need care - resolve them EXACTLY like this:
- `"what changed?"` currently routes `.gitDiff` via `isDiffRequest`, but the
  question guard would intercept it. Move the `isStatusRequest`/`isDiffRequest`/
  `isRunTestsRequest` checks BEFORE the question guard (they are read-only
  local commands - safe). Final order: screen → status → diff → tests →
  question-guard → computerUse → mutating → readOnly. Keep the existing test
  `routerPreservesClearLocalStatusDiffAndTestCommandsBeforeMutatingWords` green.
- `"can you search the git history for the bug?"`: after stripping, "search"
  is the leading token → desktopAction by the gate. That is ACCEPTABLE
  behavior (it is an imperative request); change the expected value in the
  matrix to `.codexDesktopAction` and note that desktop turns are now
  readOnly-sandboxed anyway (step 1). The row exists to force you to notice
  the interaction.

Run the FULL suite; some pre-existing router tests may legitimately change
expectation (e.g. a question-phrased mutating test). Update an existing
test's expectation ONLY when the matrix above justifies it, and list every
such change in your report.

**Verify**: full test command → `** TEST SUCCEEDED **`.

### Step 4: Manual smoke (operator-visible behavior change)

Build and run the app locally, then via the DEBUG URL scheme (no microphone
needed) exercise one utterance per class:

```
open -a "$PWD/DerivedData/Build/Products/Debug/Lorelei.app"
open -a "$PWD/DerivedData/Build/Products/Debug/Lorelei.app" "lorelei://run?prompt=should%20I%20add%20tests%20here%3F"
```

Expected: the toolbar shows a normal read-only response (no file changes). A
write-y follow-up ("update the readme title") should show the approval flow
or a workspaceWrite run per the matrix.

**Verify**: describe observed routing in your report (the debug panel logs
`Route: <label>` lines via `recordDebugEvent`).

## Test plan

Steps 1 and 3 above: 1 executor payload test + ~12 router matrix tests, all
in `LoreleiTests/LoreleiTests.swift` next to the existing router tests.

## Done criteria

- [ ] Full suite passes, including the 12-row matrix and the readOnly
      desktop-turn payload test
- [ ] `grep -n "sandboxPolicy" Lorelei/CodexAppServerExecutor.swift` shows
      `runDesktopAction` passing `"readOnly"`
- [ ] Every changed pre-existing test expectation is listed in the report
- [ ] `git diff --stat` touches only the three in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- `runDesktopAction`'s body does not forward to a run path with a
  `sandboxPolicy` parameter (drift in the executor) - report the actual shape.
- More than 3 pre-existing router tests need expectation changes - the
  heuristic is interacting more than this plan predicted; report the list
  instead of rewriting the suite.
- The manual smoke shows desktop actions failing outright under the readOnly
  sandbox (e.g. codex refuses to run the turn) - report; the fallback
  (workspaceWrite for desktop) is an owner decision.

## Maintenance notes

- BEHAVIOR CHANGE for review: question-phrased utterances no longer mutate;
  desktop turns now request approval for any Codex-side file write. If users
  report extra approval prompts during desktop tasks, that is this change
  working as designed - the owner may decide to relax specific cases.
- The politeness-prefix list is English-only; when Japanese STT lands (see
  README known limitations), the router needs locale-aware handling - a
  follow-up, not this plan.
- Any future keyword added to the bare-word lists inherits the leading-token
  gate automatically; phrase matches do not - add phrases deliberately.
