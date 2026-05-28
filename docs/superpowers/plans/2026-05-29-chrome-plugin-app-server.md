# Chrome Plugin App Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Chrome-focused Lorelei desktop actions through Codex App Server's Chrome plugin while keeping Computer Use for visual desktop control and adding a best-effort Chrome Memory Saver preflight.

**Architecture:** App Server thread config should enable both Chrome and Computer Use plugins. Prompt routing should prefer the Chrome plugin for Chrome/browser tasks that do not require visual inspection, and fall back to Computer Use only for visual UI interaction. A small preflight hook runs before App Server startup so production can wake Chrome Memory Saver discarded tabs without blocking non-Chrome actions.

**Tech Stack:** Swift, Swift Testing, macOS AppKit app, Codex App Server JSON protocol, Chrome DevTools remote debugging/CDP via a short Node.js helper.

---

## File Structure

- `leanring-buddy/CodexAppServerProtocol.swift`: update App Server plugin config so Chrome and Computer Use are both enabled for desktop turns.
- `leanring-buddy/LoreleiCommandRouter.swift`: update desktop action prompts so Chrome-only browser tasks prefer Chrome plugin instead of `lorelei.foreground_app`.
- `leanring-buddy/CodexAppServerExecutor.swift`: add a generic preflight hook and trace event before the App Server transport is created.
- `leanring-buddy/CodexChromeMemorySaverPreflight.swift`: create the production preflight that checks Chrome remote debugging targets and wakes targets that fail a short CDP attach/detach probe.
- `leanring-buddy/CompanionManager.swift`: wire the production preflight into the default App Server executor and keep trace output visible in the Debug panel.
- `leanring-buddyTests/leanring_buddyTests.swift`: add/adjust unit tests for plugin config, prompts, preflight behavior, and the Chrome preflight helper.
- `docs/chrome-memory-saver-auto-connect-memo.md`: already contains the investigation memo; append implementation notes if the preflight behavior changes.

---

### Task 1: Enable Chrome Plugin and Update Browser Prompts

**Files:**
- Modify: `leanring-buddy/CodexAppServerProtocol.swift`
- Modify: `leanring-buddy/LoreleiCommandRouter.swift`
- Test: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Write the failing tests**

In `leanring-buddyTests/leanring_buddyTests.swift`, replace `appServerThreadStartDisablesChromePluginForDesktopActions` with:

```swift
@Test func appServerThreadStartEnablesChromeAndComputerUsePluginsForDesktopActions() throws {
    let request = CodexAppServerProtocol.threadStartRequest(id: 2, cwd: "/Users/example")
    let params = try #require(request["params"] as? [String: Any])
    let config = try #require(params["config"] as? [String: Any])
    let plugins = try #require(config["plugins"] as? [String: Any])
    let chromePlugin = try #require(plugins["chrome@openai-bundled"] as? [String: Any])
    let computerUsePlugin = try #require(plugins["computer-use@openai-bundled"] as? [String: Any])

    #expect(chromePlugin["enabled"] as? Bool == true)
    #expect(computerUsePlugin["enabled"] as? Bool == true)
}
```

Update `routerMapsChromeURLRequestToAppServerDesktopAction` expectations:

```swift
#expect(prompt.contains("https://chatgpt.com"))
#expect(prompt.contains("Google Chrome"))
#expect(prompt.contains("Chrome plugin"))
#expect(prompt.contains("Do not use Computer Use"))
#expect(prompt.contains("Do not call lorelei.foreground_app"))
#expect(prompt.contains("Do not search"))
```

Update `desktopActionPromptRequiresAppServerControlPlaneAndScopedDesktopActions` expectations:

```swift
#expect(prompt.contains("Codex App Server"))
#expect(prompt.contains("Chrome plugin"))
#expect(prompt.contains("Computer Use plugin"))
#expect(prompt.contains("visual UI inspection"))
#expect(prompt.contains("lorelei.foreground_app"))
#expect(prompt.contains("Do not rely on caller-side local shortcuts."))
#expect(prompt.contains("Do not commit changes."))
#expect(!prompt.contains("non-interactive codex exec"))
#expect(prompt.contains("open TextEdit and type hello"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/appServerThreadStartEnablesChromeAndComputerUsePluginsForDesktopActions -only-testing:leanring-buddyTests/leanring_buddyTests/routerMapsChromeURLRequestToAppServerDesktopAction -only-testing:leanring-buddyTests/leanring_buddyTests/desktopActionPromptRequiresAppServerControlPlaneAndScopedDesktopActions
```

Expected: FAIL because Chrome is still disabled and browser-open prompts still require `lorelei.foreground_app`.

- [ ] **Step 3: Update App Server plugin config**

In `leanring-buddy/CodexAppServerProtocol.swift`, replace `desktopActionConfigOverrides()` with:

```swift
private static func desktopActionConfigOverrides() -> [String: Any] {
    [
        "plugins": [
            "chrome@openai-bundled": [
                "enabled": true
            ],
            "computer-use@openai-bundled": [
                "enabled": true
            ]
        ]
    ]
}
```

- [ ] **Step 4: Update the general desktop action prompt**

In `CodexPromptBuilder.desktopActionPrompt(for:)`, replace the current multiline string body with:

```swift
"""
Use Codex App Server's interactive control plane for every desktop operation.
For Chrome and browser tasks, prefer the Codex Chrome plugin when the task can be completed through browser automation without visual desktop inspection.
Use the Codex Computer Use plugin only when visual UI inspection, clicking, typing, scrolling, dragging, key presses, or non-browser desktop control are actually needed.
Before Computer Use inspects a desktop app, call lorelei.foreground_app for that target app. If Computer Use reports cgWindowNotFound, call lorelei.foreground_app once more before retrying visual inspection.
For non-Chrome app or URL opening, call lorelei.foreground_app before visual inspection so the target app is visible in the current macOS Space.
Follow the Codex Computer Use confirmation and safety policy for risky UI actions.
Do not rely on caller-side local shortcuts.
Do not commit changes.

User request:
\(prompt)
"""
```

- [ ] **Step 5: Update the Chrome URL-only prompt**

In `browserOpenPrompt(command:originalCommand:)`, replace the returned multiline string with:

```swift
"""
Open \(urlString) in Google Chrome using the Chrome plugin through Codex App Server.
Use the Chrome plugin to create or select a Chrome tab for "\(urlString)".
After the Chrome plugin succeeds, reply with the result in one sentence.
Do not use Computer Use, shell commands, or local macOS shortcuts.
Do not call lorelei.foreground_app for this Chrome-only task.
Do not search, type into the page, click submit, or perform any additional browser interaction.

Original user request:
\(originalCommand)
"""
```

- [ ] **Step 6: Run focused tests to verify they pass**

Run the same focused `xcodebuild test ... -only-testing:...` command from Step 2.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add leanring-buddy/CodexAppServerProtocol.swift leanring-buddy/LoreleiCommandRouter.swift leanring-buddyTests/leanring_buddyTests.swift
git commit -m "feat: prefer chrome plugin for browser actions"
```

---

### Task 2: Add App Server Preflight Hook

**Files:**
- Modify: `leanring-buddy/CodexAppServerExecutor.swift`
- Test: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Write failing preflight tests**

Add these tests near the existing App Server executor tests:

```swift
@Test func appServerExecutorRunsPreflightBeforeStartingTransport() async throws {
    let preflightCounter = LaunchCounter()
    let transportCounter = LaunchCounter()
    let transport = FakeCodexAppServerTransport(lines: [
        #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
        #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
        #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
        #"{"method":"turn/completed","params":{"status":"completed"}}"#
    ])
    let executor = CodexAppServerExecutor(
        preflight: { prompt in
            preflightCounter.increment()
            #expect(prompt == "open Chrome")
            return .completed("Chrome preflight ok")
        },
        makeTransport: {
            transportCounter.increment()
            return transport
        },
        approvalHandler: { _ in .cancel }
    )

    let result = await executor.runDesktopAction(prompt: "open Chrome", cwd: "/Users/example")

    #expect(result.status == .succeeded)
    #expect(result.summary == "Done")
    #expect(preflightCounter.value == 1)
    #expect(transportCounter.value == 1)
}

@Test func appServerExecutorStopsWhenPreflightFails() async throws {
    let transportCounter = LaunchCounter()
    let executor = CodexAppServerExecutor(
        preflight: { _ in .failed("Chrome preflight failed.") },
        makeTransport: {
            transportCounter.increment()
            return FakeCodexAppServerTransport(lines: [])
        },
        approvalHandler: { _ in .cancel }
    )

    let result = await executor.runDesktopAction(prompt: "open Chrome", cwd: "/Users/example")

    #expect(result.status == .failed)
    #expect(result.summary.contains("Chrome preflight failed."))
    #expect(transportCounter.value == 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/appServerExecutorRunsPreflightBeforeStartingTransport -only-testing:leanring-buddyTests/leanring_buddyTests/appServerExecutorStopsWhenPreflightFails
```

Expected: FAIL because `CodexAppServerExecutor` has no `preflight` parameter and no `CodexAppServerPreflightResult` type.

- [ ] **Step 3: Add preflight types and trace event**

In `leanring-buddy/CodexAppServerExecutor.swift`, after `enum CodexAppServerApprovalDecision`, add:

```swift
enum CodexAppServerPreflightResult: Equatable, Sendable {
    case completed(String)
    case warning(String)
    case failed(String)
}

typealias CodexAppServerPreflight = @Sendable (_ prompt: String) async -> CodexAppServerPreflightResult
```

Inside `CodexAppServerTraceEvent`, add:

```swift
static func preflight(_ detail: String) -> Self {
    Self("preflight \(detail)")
}
```

- [ ] **Step 4: Wire preflight into the executor**

Add a stored property:

```swift
private let preflight: CodexAppServerPreflight
```

Update the initializer signature to include this argument before `makeTransport`:

```swift
preflight: @escaping CodexAppServerPreflight = { _ in .completed("No preflight configured.") },
```

Assign it in the initializer:

```swift
self.preflight = preflight
```

At the top of `runDesktopAction(prompt:cwd:)`, create the trace buffer before starting the transport and run preflight:

```swift
let traceBuffer = CodexAppServerTraceBuffer()
let preflightResult = await preflight(prompt)
switch preflightResult {
case .completed(let detail):
    recordTrace(.preflight(detail), to: traceBuffer)
case .warning(let detail):
    recordTrace(.preflight("warning: \(detail)"), to: traceBuffer)
case .failed(let detail):
    recordTrace(.preflight("failed: \(detail)"), to: traceBuffer)
    return WorkspaceCommandResult(
        summary: detail + traceBuffer.diagnosticSuffix(),
        status: .failed
    )
}
```

Remove the later duplicate `let traceBuffer = CodexAppServerTraceBuffer()` so the rest of the method uses the same buffer.

- [ ] **Step 5: Run focused tests to verify they pass**

Run the same focused command from Step 2.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/CodexAppServerExecutor.swift leanring-buddyTests/leanring_buddyTests.swift
git commit -m "feat: add app server preflight hook"
```

---

### Task 3: Implement Chrome Memory Saver Preflight

**Files:**
- Create: `leanring-buddy/CodexChromeMemorySaverPreflight.swift`
- Modify: `leanring-buddy/CompanionManager.swift`
- Modify: `docs/chrome-memory-saver-auto-connect-memo.md`
- Test: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Write failing unit tests**

Add these tests near the App Server tests:

```swift
@Test func chromeMemorySaverPreflightSkipsNonChromePrompt() async throws {
    let runner = ChromeMemorySaverScriptRunnerRecorder(
        execution: WorkspaceProcessExecution(reason: .exited(0), stdout: #"{"ok":true,"pageTargets":0,"woken":0}"#, stderr: "")
    )
    let preflight = CodexChromeMemorySaverPreflight(scriptRunner: runner.run)

    let result = await preflight.run(prompt: "open TextEdit")

    #expect(result == .completed("Chrome preflight skipped: prompt does not mention Chrome or a browser."))
    #expect(runner.calls.isEmpty)
}

@Test func chromeMemorySaverPreflightRunsForChromePromptAndReportsWakeCount() async throws {
    let runner = ChromeMemorySaverScriptRunnerRecorder(
        execution: WorkspaceProcessExecution(reason: .exited(0), stdout: #"{"ok":true,"pageTargets":6,"woken":2}"#, stderr: "")
    )
    let preflight = CodexChromeMemorySaverPreflight(scriptRunner: runner.run)

    let result = await preflight.run(prompt: "open chatgpt.com in Chrome")

    #expect(result == .completed("Chrome preflight checked 6 tabs and woke 2 sleeping tabs."))
    #expect(runner.calls.count == 1)
}

@Test func chromeMemorySaverPreflightWarnsButDoesNotFailWhenScriptFails() async throws {
    let runner = ChromeMemorySaverScriptRunnerRecorder(
        execution: WorkspaceProcessExecution(reason: .exited(1), stdout: "", stderr: "DevToolsActivePort missing")
    )
    let preflight = CodexChromeMemorySaverPreflight(scriptRunner: runner.run)

    let result = await preflight.run(prompt: "open chatgpt.com in Chrome")

    #expect(result == .warning("Chrome preflight could not complete: DevToolsActivePort missing"))
}
```

Add this recorder near the existing test helper types:

```swift
private final class ChromeMemorySaverScriptRunnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private let execution: WorkspaceProcessExecution

    init(execution: WorkspaceProcessExecution) {
        self.execution = execution
    }

    func run(script: String, timeoutSeconds: TimeInterval) async -> WorkspaceProcessExecution {
        lock.lock()
        calls.append(script)
        lock.unlock()
        #expect(timeoutSeconds == 8)
        return execution
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/chromeMemorySaverPreflightSkipsNonChromePrompt -only-testing:leanring-buddyTests/leanring_buddyTests/chromeMemorySaverPreflightRunsForChromePromptAndReportsWakeCount -only-testing:leanring-buddyTests/leanring_buddyTests/chromeMemorySaverPreflightWarnsButDoesNotFailWhenScriptFails
```

Expected: FAIL because `CodexChromeMemorySaverPreflight` does not exist.

- [ ] **Step 3: Create the preflight file**

Create `leanring-buddy/CodexChromeMemorySaverPreflight.swift`:

```swift
//
//  CodexChromeMemorySaverPreflight.swift
//  leanring-buddy
//
//  Best-effort Chrome DevTools preflight for waking Memory Saver discarded tabs
//  before Codex App Server starts chrome-devtools-mcp with --autoConnect.
//

import Foundation

typealias ChromeMemorySaverScriptRunner = @Sendable (
    _ script: String,
    _ timeoutSeconds: TimeInterval
) async -> WorkspaceProcessExecution

struct CodexChromeMemorySaverPreflight {
    private let scriptRunner: ChromeMemorySaverScriptRunner
    private let timeoutSeconds: TimeInterval

    init(
        timeoutSeconds: TimeInterval = 8,
        scriptRunner: ChromeMemorySaverScriptRunner? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.scriptRunner = scriptRunner ?? Self.liveScriptRunner
    }

    func run(prompt: String) async -> CodexAppServerPreflightResult {
        guard Self.shouldRun(for: prompt) else {
            return .completed("Chrome preflight skipped: prompt does not mention Chrome or a browser.")
        }

        let execution = await scriptRunner(Self.nodeScript, timeoutSeconds)
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .exited(let status) = execution.reason, status == 0 else {
            let detail = stderr.isEmpty ? "script exited without JSON output" : stderr
            return .warning("Chrome preflight could not complete: \(detail)")
        }

        guard let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true else {
            return .warning("Chrome preflight could not parse script output.")
        }

        let pageTargets = root["pageTargets"] as? Int ?? 0
        let woken = root["woken"] as? Int ?? 0
        return .completed("Chrome preflight checked \(pageTargets) tabs and woke \(woken) sleeping tabs.")
    }

    private static func shouldRun(for prompt: String) -> Bool {
        let lowercased = prompt.lowercased()
        return lowercased.contains("chrome")
            || lowercased.contains("browser")
            || lowercased.contains("chatgpt")
    }

    private static func liveScriptRunner(script: String, timeoutSeconds: TimeInterval) async -> WorkspaceProcessExecution {
        let fileManager = FileManager.default
        let scriptURL = fileManager.temporaryDirectory
            .appendingPathComponent("lorelei-chrome-preflight-\(UUID().uuidString).mjs")
        defer { try? fileManager.removeItem(at: scriptURL) }

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return WorkspaceProcessExecution(
                reason: .failedToStart(error),
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let nodeURL = URL(fileURLWithPath: "/usr/bin/env")
        let runner = WorkspaceProcessRunner()
        return await runner.run(
            executableURL: nodeURL,
            arguments: ["node", scriptURL.path],
            currentDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            timeoutSeconds: timeoutSeconds,
            prelaunchDelay: 0,
            onLaunch: nil
        )
    }

    private static let nodeScript = #"""
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const portPath = path.join(os.homedir(), 'Library', 'Application Support', 'Google', 'Chrome', 'DevToolsActivePort');
const timeout = (ms, label) => new Promise((_, reject) => setTimeout(() => reject(new Error(`${label} timed out`)), ms));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const [rawPort, rawPath] = (await fs.readFile(portPath, 'utf8'))
  .split('\n')
  .map(line => line.trim())
  .filter(Boolean);

if (!rawPort || !rawPath) {
  throw new Error('Invalid DevToolsActivePort');
}

const ws = new WebSocket(`ws://127.0.0.1:${rawPort}${rawPath}`);
await Promise.race([
  new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  }),
  timeout(1500, 'WebSocket open')
]);

let nextId = 1;
const pending = new Map();
ws.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  if (!message.id) return;
  const callbacks = pending.get(message.id);
  if (!callbacks) return;
  pending.delete(message.id);
  if (message.error) callbacks.reject(new Error(message.error.message || JSON.stringify(message.error)));
  else callbacks.resolve(message.result || {});
});

function send(method, params = {}, ms = 1200) {
  const id = nextId++;
  const body = JSON.stringify({ id, method, params });
  const response = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  ws.send(body);
  return Promise.race([response, timeout(ms, method)]);
}

async function probeTarget(targetId) {
  const attached = await send('Target.attachToTarget', { targetId, flatten: true }, 1200);
  if (attached.sessionId) {
    await send('Target.detachFromTarget', { sessionId: attached.sessionId }, 1200).catch(() => {});
  }
}

const { targetInfos } = await send('Target.getTargets', {}, 1500);
const pageTargets = targetInfos.filter(target => {
  return target.type === 'page'
    && target.url
    && !target.url.startsWith('chrome://')
    && !target.url.startsWith('devtools://');
});

let woken = 0;
for (const target of pageTargets) {
  try {
    await probeTarget(target.targetId);
  } catch {
    await send('Target.activateTarget', { targetId: target.targetId }, 1500).catch(() => {});
    await sleep(250);
    woken += 1;
  }
}

ws.close();
console.log(JSON.stringify({ ok: true, pageTargets: pageTargets.length, woken }));
"""#
}
```

- [ ] **Step 4: Wire production preflight into CompanionManager**

In `runCodexAppServerDesktopAction(prompt:)`, before creating `CodexAppServerExecutor`, add:

```swift
let chromePreflight = CodexChromeMemorySaverPreflight()
```

Then pass it into the executor:

```swift
preflight: { prompt in
    await chromePreflight.run(prompt: prompt)
},
```

- [ ] **Step 5: Append implementation note to docs**

Append this to `docs/chrome-memory-saver-auto-connect-memo.md`:

```markdown

Implementation note: Lorelei now runs a best-effort Chrome preflight before App Server desktop actions whose prompts mention Chrome, browser, or ChatGPT. The preflight talks directly to Chrome's remote debugging WebSocket, probes page targets with a short CDP attach/detach timeout, and activates only targets that fail the probe so discarded tabs are woken before `chrome-devtools-mcp --autoConnect` enumerates pages.
```

- [ ] **Step 6: Run focused tests to verify they pass**

Run the same focused command from Step 2.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add leanring-buddy/CodexChromeMemorySaverPreflight.swift leanring-buddy/CompanionManager.swift leanring-buddyTests/leanring_buddyTests.swift docs/chrome-memory-saver-auto-connect-memo.md
git commit -m "feat: wake chrome memory saver tabs before app server"
```

---

### Task 4: Full Verification and Live Smoke

**Files:**
- Modify only if verification reveals a bug in files touched by Tasks 1-3.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Run a live App Server Chrome smoke if Chrome remote debugging is available**

Run:

```bash
node --input-type=module <<'NODE'
import { spawn } from 'node:child_process';
console.log('Manual smoke is intentionally run from Lorelei UI or app-server debug harness; verify the app opens https://chatgpt.com through the Chrome plugin without Computer Use.');
NODE
```

Expected: no code changes. Record the manual smoke result in the final implementation summary.

- [ ] **Step 3: Commit verification docs if changed**

Only if Task 4 caused documentation edits:

```bash
git add docs/chrome-memory-saver-auto-connect-memo.md
git commit -m "docs: record chrome plugin smoke results"
```

If no files changed, do not create an empty commit.

---

## Self-Review

**Spec coverage:** The plan enables Chrome plugin usage, keeps Computer Use available for visual UI work, adds a Memory Saver preflight, records the investigation memo, and includes tests plus full verification.

**Placeholder scan:** No TBD/TODO/fill-in placeholders remain. Every code-changing step includes concrete code or exact expected assertions.

**Type consistency:** `CodexAppServerPreflightResult`, `CodexAppServerPreflight`, `CodexChromeMemorySaverPreflight`, and `ChromeMemorySaverScriptRunner` names are used consistently across tasks.
