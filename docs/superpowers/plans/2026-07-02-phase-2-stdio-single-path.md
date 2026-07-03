# Phase 2: App Server stdio migration + single execution path - Implementation Plan

> **For agentic workers:** This plan is executed by Codex (gpt-5.5) task-by-task, reviewed by the planner between tasks. Steps use checkbox (`- [ ]`) syntax for tracking. Codex must not run git commands that write; the reviewer stages and commits. Codex builds with `-derivedDataPath ./DerivedData`; the reviewer runs the test suite.

**Goal:** Replace the experimental WebSocket App Server transport with stdio JSONL, pin the turn model to gpt-5.5, remove the local confirmation flow, and remove all Chrome-specific routing so there is exactly one execution path.

**Architecture:** The `CodexAppServerTransporting` seam (`send(line:)` / `nextLine()` / `terminate()`) already fits line-oriented transports, so the migration is a new stdio implementation plus deletion of the WebSocket one; the protocol layer (`encodeLine` / `parseInboundLine`) is untouched. Confirmation and Chrome routing removal are pure deletions that rewire `handleFinalTranscriptLocally` to execute routed actions directly. App Server approval bridging (`pendingCodexAppServerApproval`, `requestCodexAppServerApproval`, `resolvePendingCodexAppServerApproval`) is explicitly KEPT (spec decision #5).

**Tech Stack:** Swift concurrency (actor, `FileHandle.AsyncBytes.lines`), XCTest, codex-cli 0.142.x `app-server` (stdio JSONL is its default transport).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md`. Decisions #4 (no local confirmation), #5 (keep approval bridging), #13 (remove Chrome routing).
- Model for App Server turns is exactly `gpt-5.5`, set per-turn.
- Do NOT touch: `CodexAppServerDesktopForegroundTool.swift` (general-purpose, kept for phase 3), the `codex exec` paths in `CodexExecutor.swift` (readOnly/workspaceWrite/screen stay, minus their confirmation gate), approval bridging code.
- Build: `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData build`
- Reviewer test command: `xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -skip-testing:LoreleiUITests`
- Commit messages in English; one commit per task by the reviewer.

---

### Task 1: Stdio transport replaces WebSocket transport

**Files:**
- Modify: `Lorelei/CodexAppServerExecutor.swift` (replace `CodexAppServerProcessTransport` lines ~478-662, `CodexAppServerLaunch.make` lines ~99-111)
- Test: `LoreleiTests/LoreleiTests.swift` (add transport framing tests; existing fake-transport executor tests must keep passing unchanged)

**Interfaces:**
- Consumes: `protocol CodexAppServerTransporting` (`send(line:) async throws`, `nextLine() async throws -> String?`, `terminate() async`) - unchanged.
- Produces: `actor CodexAppServerStdioTransport: CodexAppServerTransporting` with `static func make(codexExecutableURL: URL?, fileManager: FileManager) async throws -> CodexAppServerStdioTransport` (same default-factory role as the old `CodexAppServerProcessTransport.make()`), plus an internal `static func make(executableURL: URL, arguments: [String])` for tests.

- [ ] **Step 1: Write the failing framing tests** (in `LoreleiTests.swift`)

```swift
func stdioTransportRoundTripsOneJSONLineThroughChildProcess() async throws {
    // /bin/cat echoes stdin to stdout, which is exactly JSONL round-tripping.
    let transport = try await CodexAppServerStdioTransport.make(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        arguments: []
    )
    try await transport.send(line: "{\"id\":1,\"method\":\"initialize\"}")
    let echoed = try await transport.nextLine()
    XCTAssertEqual(echoed, "{\"id\":1,\"method\":\"initialize\"}")
    await transport.terminate()
}

func stdioTransportAppendsExactlyOneNewlinePerSend() async throws {
    let transport = try await CodexAppServerStdioTransport.make(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        arguments: []
    )
    try await transport.send(line: "{\"a\":1}\n")   // already newline-terminated
    try await transport.send(line: "{\"b\":2}")      // not terminated
    let first = try await transport.nextLine()
    let second = try await transport.nextLine()
    XCTAssertEqual(first, "{\"a\":1}")
    XCTAssertEqual(second, "{\"b\":2}")
    await transport.terminate()
}

func stdioTransportReturnsNilAfterChildExits() async throws {
    let transport = try await CodexAppServerStdioTransport.make(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: []
    )
    let line = try await transport.nextLine()
    XCTAssertNil(line)
    await transport.terminate()
}
```

- [ ] **Step 2: Run the new tests, verify they fail to compile** (`CodexAppServerStdioTransport` not defined).

- [ ] **Step 3: Implement the stdio transport** in `CodexAppServerExecutor.swift`, deleting `CodexAppServerProcessTransport` (its `make`, `waitUntilReady`, `drain`, WebSocket send/receive) and `CodexAppServerProcessTransportError.invalidWebSocketMessage`/`startupTimedOut`:

```swift
actor CodexAppServerStdioTransport: CodexAppServerTransporting {
    private let process: Process
    private let stdinHandle: FileHandle
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    private var stderrDrainTask: Task<Void, Never>?

    private init(process: Process, stdinHandle: FileHandle, stdoutHandle: FileHandle, stderrHandle: FileHandle) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.lines = stdoutHandle.bytes.lines.makeAsyncIterator()
        self.stderrDrainTask = Task.detached {
            // Keep the pipe from filling; codex logs startup notices to stderr.
            for try? await _ in stderrHandle.bytes.lines {}
        }
    }

    static func make(
        codexExecutableURL: URL? = nil,
        fileManager: FileManager = .default
    ) async throws -> CodexAppServerStdioTransport {
        let launch = try CodexAppServerLaunch.make(
            codexExecutableURL: codexExecutableURL,
            fileManager: fileManager
        )
        return try await make(executableURL: launch.executableURL, arguments: launch.arguments)
    }

    static func make(executableURL: URL, arguments: [String]) async throws -> CodexAppServerStdioTransport {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        return CodexAppServerStdioTransport(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading
        )
    }

    func send(line: String) async throws {
        let payload = line.hasSuffix("\n") ? line : line + "\n"
        try stdinHandle.write(contentsOf: Data(payload.utf8))
    }

    func nextLine() async throws -> String? {
        try await lines.next()
    }

    func terminate() async {
        stderrDrainTask?.cancel()
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }
}
```

Notes for the implementer:
- Exact iterator/callable spellings may need minor adjustment to compile (e.g. `for await` over a throwing sequence); keep the observable behavior of the three tests fixed.
- `CodexAppServerExecutor.init`'s default `makeTransport` closure changes to `{ try await CodexAppServerStdioTransport.make() }`.
- Keep `CodexAppServerProcessTransportError.missingCodexExecutable` if `CodexAppServerLaunch` still throws it; drop the WebSocket-only cases. Renaming the error enum to `CodexAppServerStdioTransportError` is fine if all references update.

- [ ] **Step 4: Update `CodexAppServerLaunch.make`** to drop the `listenURL` parameter entirely and produce `["app-server"]` (stdio JSONL is codex's default transport; no `--listen`). Update its callers and any launch-args tests accordingly.

- [ ] **Step 5: Verify no WebSocket remnants**

```bash
grep -rn 'webSocket\|ws://\|readyz\|URLSessionWebSocketTask\|--listen' Lorelei LoreleiTests; echo "exit=$?"
```

Expected: nothing, exit=1.

- [ ] **Step 6: Build; reviewer runs tests; reviewer commits** (`feat: migrate app server transport to stdio JSONL`).

---

### Task 2: Pin App Server turns to gpt-5.5

**Files:**
- Modify: `Lorelei/CodexAppServerProtocol.swift` (`turnStartRequest`, ~line 272-304)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Consumes: `turnStartRequest(id:threadID:prompt:cwd:skillInputs:)` builder.
- Produces: turn/start params containing `"model": "gpt-5.5"`; constant `CodexAppServerModel.turnModel = "gpt-5.5"`.

- [ ] **Step 1: Write the failing test**

```swift
func appServerTurnStartRequestPinsModelToGPT55() throws {
    let line = CodexAppServerMessageFactory.turnStartRequest(
        id: 3, threadID: "t-1", prompt: "open Gmail", cwd: "/tmp", skillInputs: nil
    )
    let object = try XCTUnwrap(decodeJSONObject(line))          // reuse the tests' existing JSON helpers
    let params = try XCTUnwrap(object["params"] as? [String: Any])
    XCTAssertEqual(params["model"] as? String, "gpt-5.5")
}
```

(Adapt the factory/type name and helper to the file's existing test conventions for turn/start assertions - see `appServerThreadStartEnablesChromeAndComputerUsePluginsForDesktopActions` at ~line 1039 for the established decode pattern.)

- [ ] **Step 2: Run it, verify it fails** (no `model` key).

- [ ] **Step 3: Implement**: add to `CodexAppServerProtocol.swift`

```swift
enum CodexAppServerModel {
    /// Spec decision: App Server turns run on gpt-5.5, pinned per-turn.
    static let turnModel = "gpt-5.5"
}
```

and inside `turnStartRequest`'s params construction add `"model": CodexAppServerModel.turnModel`.

- [ ] **Step 4: Build; reviewer runs tests; reviewer commits** (`feat: pin app server turns to gpt-5.5`).

---

### Task 3: Remove the local confirmation flow

**Files:**
- Modify: `Lorelei/LoreleiCommandRouter.swift` (delete `LoreleiConfirmationPolicy` ~52-61, `PendingCommandConfirmation` ~103-121)
- Modify: `Lorelei/CompanionManager.swift` (rewire `handleFinalTranscriptLocally` ~461-521; delete `pendingConfirmation` field, `confirmPendingCommand`, `cancelPendingCommand`, `requestPendingConfirmation`, `executeConfirmedCommand`, `setPendingConfirmationTitle` if unused by approvals)
- Modify: `Lorelei/WorkspaceCommandExecutor.swift` (delete `.needsConfirmation` status case ~16 and its `spokenStatus` branch ~36-37)
- Modify: `Lorelei/CompanionPanelView.swift` (remove confirm/cancel UI bound to `pendingConfirmationTitle` where it serves LOCAL confirmation; the same property may also render App Server approvals - see step 2)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Consumes: `LoreleiCommandAction` enum, `runCodexAppServerDesktopAction(prompt:wrapGenericPrompt:)`, `codexExecutor.run(...)`.
- Produces: `handleFinalTranscriptLocally(_:)` executes every routed action immediately; the KEPT approval API is unchanged: `requestCodexAppServerApproval(...)` (~536) and `resolvePendingCodexAppServerApproval(_:)` (~550).

- [ ] **Step 1: Rewrite the confirmation tests as direct-execution tests.** Replace:
  - `companionManagerRunsDesktopActionThroughInjectedAppServerRunnerAfterConfirmation` (~113) -> `companionManagerRunsDesktopActionThroughInjectedAppServerRunnerImmediately`: same fixture, but assert the app-server runner fires after `handleFinalTranscriptLocally` alone, with NO `confirmPendingCommand()` call and `pendingConfirmationTitle` never set.
  - `companionManagerRecordsDebugLogForConfirmedDesktopAction` (~338) -> same rename pattern, no confirm step.
  - Delete: `confirmationPolicyAllowsOnlySafeLocalAndScopedScreenCommandsImmediately` (~534), `confirmationPolicyRequiresPanelConfirmationForBroadCodexWriteAndDesktopActionCommands` (~541), `pendingConfirmationStoresAndClearsAction` (~584).
  - Add: `companionManagerRunsWorkspaceWriteCodexCommandImmediately` - route a mutating transcript (e.g. "update the readme") and assert `codexExecutor` receives `.workspaceWrite` without any confirmation state in between (use the existing injected-executor fixture pattern).

- [ ] **Step 2: Verify they fail, then implement the removal.** In `handleFinalTranscriptLocally`, the `switch action` cases `.codexReadOnly`, `.codexWorkspaceWrite`, `.codexDesktopAction` call the execution paths that currently live in `executeConfirmedCommand` directly (inline that method's per-case bodies, then delete it). Keep the `.codexScreen`, `.unsupported`, git/test cases as they are. Preserve untouched: `pendingCodexAppServerApproval` continuation (~103), `requestCodexAppServerApproval`, `resolvePendingCodexAppServerApproval`, and whatever published property App Server approvals use for panel display - if that is `pendingConfirmationTitle`, KEEP the property and rename it to `pendingApprovalTitle` everywhere so its remaining purpose is explicit; update `CompanionPanelView` bindings so approval accept/decline buttons still work (they call the approval resolve API, not the deleted local confirm methods). Also remove the now-dead confirmation clearing in `stop()` (~243) and `handleShortcutTransition(.pressed)` (~423).

- [ ] **Step 3: Verify zero remnants**

```bash
grep -rn 'PendingCommandConfirmation\|LoreleiConfirmationPolicy\|requiresConfirmation\|needsConfirmation\|confirmPendingCommand\|cancelPendingCommand\|executeConfirmedCommand\|requestPendingConfirmation' Lorelei LoreleiTests; echo "exit=$?"
```

Expected: nothing, exit=1.

- [ ] **Step 4: Build; reviewer runs tests; reviewer commits** (`feat: execute voice commands immediately without local confirmation`).

---

### Task 4: Remove Chrome-specific routing

**Files:**
- Delete: `Lorelei/CodexChromeMemorySaverPreflight.swift`
- Modify: `Lorelei/LoreleiCommandRouter.swift` (delete `.codexChromeBrowserOpen` case + `browserOpenPrompt` ~223-243, `isBrowserDesktopOperation` ~245-265, `requiresBrowserInteractionAfterOpen` ~267-280, `normalizedURLString`/`looksLikeDomain`/`looksLikeHost` ~282-339, chrome/safari/chatgpt special-casing inside `isComputerUseRequest` ~210-221, and the chrome-plugin guidance text in `CodexPromptBuilder` ~84-99)
- Modify: `Lorelei/CompanionManager.swift` (delete `chromeMemorySaverScriptRunner` field ~99 + init param ~135/142, the preflight wiring in `runCodexAppServerDesktopAction` ~582-585, and the `.codexChromeBrowserOpen` handling)
- Modify: `Lorelei/CodexAppServerExecutor.swift` (delete the `CodexAppServerPreflight` seam ~15-21 and its executor param/call sites - Chrome preflight was its only user)
- Modify: `Lorelei/CodexAppServerProtocol.swift` (`desktopActionConfigOverrides` ~742-753: drop `chrome@openai-bundled`, keep `computer-use@openai-bundled` for now - phase 3 replaces it)
- Modify: `Lorelei/WorkspaceCommandExecutor.swift` (drop `.codexChromeBrowserOpen` arms ~71-72/99-100)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Consumes: the routed actions from Task 3's single path.
- Produces: `LoreleiCommandAction` without `codexChromeBrowserOpen`; router sends every computer-use request (including browser phrases like "open gmail in chrome") to `.codexDesktopAction`.

- [ ] **Step 1: Update tests first.**
  - Delete: `companionManagerSkipsChromeMemorySaverPreflightForGeneralDesktopAction` (~198), `workspaceExecutorDoesNotRunChromeBrowserOpenLocally` (~757), `desktopActionPromptKeepsBrowserAutomationOnChromePluginWhenVisualInspectionIsNotNeeded` (~569), `desktopActionPromptScopesForegroundAppToNonChromeOpeningOnly` (~577), all five `chromeMemorySaverPreflight*` tests (~1597-1670), `liveAppServerOpensChromeThroughChromePlugin` (~1903).
  - Rewrite: `routerMapsChromeURLRequestToAppServerDesktopAction` (~497), `routerMapsChromeTypingRequestToDesktopActionWithoutReadOnlyCodex` (~514), `routerDoesNotUseURLOnlyPromptWhenChromeRequestNeedsTyping` (~521) into a single `routerMapsBrowserRequestsToDesktopAction` asserting "open gmail in chrome" and "type hello into the search box in chrome" both route to `.codexDesktopAction`.
  - Rewrite: `appServerThreadStartEnablesChromeAndComputerUsePluginsForDesktopActions` (~1039) -> `appServerThreadStartEnablesComputerUsePluginForDesktopActions` (chrome plugin absent, computer-use present).
  - Keep all `foregroundDynamicTool*` tests untouched (the foreground tool is general-purpose and stays).

- [ ] **Step 2: Implement the deletions** listed under Files, in dependency order: tests -> router -> CompanionManager -> executor seam -> protocol overrides -> workspace executor -> `rm Lorelei/CodexChromeMemorySaverPreflight.swift`.

- [ ] **Step 3: Verify zero remnants**

```bash
grep -rni 'chromeBrowserOpen\|MemorySaver\|chrome@openai-bundled\|CodexAppServerPreflight\|browserOpenPrompt' Lorelei LoreleiTests; echo "exit=$?"
```

Expected: nothing, exit=1. (Plain "chrome" may legitimately remain only in `CodexAppServerDesktopForegroundTool.swift` app-name aliases.)

- [ ] **Step 4: Build; reviewer runs tests; reviewer commits** (`feat: remove chrome-specific routing for a single execution path`).

---

### Task 5: Schema regeneration script + phase PR

**Files:**
- Create: `scripts/update-appserver-schema.sh`
- Create: `docs/appserver-schema/` (generated bundle, committed for reference/diffing across CLI upgrades)

**Interfaces:**
- Consumes: installed codex CLI.
- Produces: a repeatable `./scripts/update-appserver-schema.sh` that snapshots the protocol schema the app was written against.

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Snapshot the app-server protocol schema for the installed codex CLI.
# Re-run after every codex upgrade and review the diff against the Swift
# protocol layer (CodexAppServerProtocol.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/appserver-schema
codex app-server generate-json-schema --out docs/appserver-schema
codex --version > docs/appserver-schema/CODEX_VERSION
```

`chmod +x scripts/update-appserver-schema.sh`, run it once, and confirm `docs/appserver-schema/CODEX_VERSION` says `codex-cli 0.142.4`.

- [ ] **Step 2: Full verification.** Build, then the reviewer runs the full suite INCLUDING UI tests:

```bash
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS'
```

- [ ] **Step 3: Reviewer commits** (`chore: snapshot app server protocol schema`), pushes `phase-2-stdio-single-path`, and opens the phase PR referencing the spec and PRD #2.
