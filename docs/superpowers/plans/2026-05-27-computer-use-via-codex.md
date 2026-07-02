# Computer Use Via Codex Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Lorelei trigger Codex app-style Computer Use from confirmed voice commands through the existing `codex exec` path.

**Architecture:** Keep Lorelei as a voice-first Codex controller. Route Computer Use-style transcripts to `.codexComputerUse`, require Lorelei panel confirmation, build a concise Computer Use prompt, and run `codex exec` without suppressing the user's Codex config so the existing Computer Use plugin/MCP server can load.

**Tech Stack:** Swift, Swift Testing, SwiftUI/AppKit macOS app, Codex CLI.

---

## File Structure

- Modify `leanring-buddy/LoreleiCommandRouter.swift`
  - Keep routing and confirmation policy local.
  - Tighten only the Computer Use prompt text.
- Modify `leanring-buddy/CodexExecutor.swift`
  - No production behavior change is expected unless a test exposes a gap.
  - Preserve user config loading by not adding `--ignore-user-config`.
- Modify `leanring-buddyTests/leanring_buddyTests.swift`
  - Add focused unit tests for Computer Use routing, confirmation, prompt text, and command arguments.
- Manual E2E only
  - Launch Lorelei locally and verify the real Codex Computer Use path. Do not automate real desktop UI actions in unit tests.

## Scope Check

This plan covers one subsystem: voice-triggered Computer Use through Codex CLI. It does not implement a direct Swift MCP client or a standalone Computer Use runtime.

### Task 1: Add Focused Computer Use Tests

**Files:**
- Modify: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Add router tests for explicit Computer Use phrases**

Insert these tests near the existing router Computer Use tests:

```swift
    @Test func routerMapsBrowserOperationToCodexComputerUse() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("open the browser and search for Swift concurrency") == .codexComputerUse("open the browser and search for Swift concurrency"))
    }

    @Test func routerMapsExplicitComputerUsePhraseToCodexComputerUse() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("use computer use to open System Settings") == .codexComputerUse("use computer use to open System Settings"))
    }
```

- [ ] **Step 2: Run the router tests and verify current behavior**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/routerMapsBrowserOperationToCodexComputerUse -only-testing:leanring-buddyTests/leanring_buddyTests/routerMapsExplicitComputerUsePhraseToCodexComputerUse
```

Expected: both tests pass if existing routing is already sufficient. If the test target name differs on this machine, run the full test target command from Task 4 and confirm these two tests are included.

- [ ] **Step 3: Add a prompt test that captures the agreed Computer Use contract**

Insert this test near `workspaceWritePromptIncludesNoCommitGuard`:

```swift
    @Test func computerUsePromptMentionsPluginSafetyPolicyAndNoCommitGuard() async throws {
        let prompt = CodexPromptBuilder.computerUsePrompt(for: "open the browser")

        #expect(prompt.contains("existing Codex Computer Use plugin"))
        #expect(prompt.contains("Codex Computer Use confirmation and safety policy"))
        #expect(prompt.contains("Do not commit changes."))
        #expect(prompt.contains("open the browser"))
    }
```

- [ ] **Step 4: Run the new prompt test and verify it fails before implementation**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/computerUsePromptMentionsPluginSafetyPolicyAndNoCommitGuard
```

Expected: FAIL because the current prompt does not mention the existing Codex Computer Use plugin or confirmation and safety policy.

### Task 2: Tighten The Computer Use Prompt

**Files:**
- Modify: `leanring-buddy/LoreleiCommandRouter.swift`
- Test: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Replace `CodexPromptBuilder.computerUsePrompt(for:)` with the minimal agreed prompt**

In `leanring-buddy/LoreleiCommandRouter.swift`, replace only the `computerUsePrompt(for:)` body with:

```swift
    static func computerUsePrompt(for prompt: String) -> String {
        """
        Use the existing Codex Computer Use plugin when desktop UI operation is needed.
        Follow the Codex Computer Use confirmation and safety policy for risky UI actions.
        Do not commit changes.

        User request:
        \(prompt)
        """
    }
```

- [ ] **Step 2: Run the prompt test and verify it passes**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/computerUsePromptMentionsPluginSafetyPolicyAndNoCommitGuard
```

Expected: PASS.

- [ ] **Step 3: Commit the prompt contract**

Run:

```bash
git add leanring-buddy/LoreleiCommandRouter.swift leanring-buddyTests/leanring_buddyTests.swift
git commit -m "feat: clarify Computer Use Codex prompt"
```

### Task 3: Assert Codex Uses User Config

**Files:**
- Modify: `leanring-buddyTests/leanring_buddyTests.swift`
- Modify: `leanring-buddy/CodexExecutor.swift` only if the test reveals an issue.

- [ ] **Step 1: Add a command construction test for user config loading**

Insert this test after `codexExecutorBuildsWorkspaceWriteCommand`:

```swift
    @Test func codexExecutorDoesNotIgnoreUserConfigForWorkspaceWriteCommand() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let recorder = CodexCommandRecorder(finalMessage: "Computer-use answer")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        _ = await executor.run(
            .workspaceWrite,
            prompt: CodexPromptBuilder.computerUsePrompt(for: "open the browser"),
            workspacePath: directoryURL.path
        )

        #expect(recorder.arguments?.contains("--ignore-user-config") == false)
        #expect(recorder.arguments?.contains("--sandbox") == true)
        #expect(recorder.arguments?.contains("workspace-write") == true)
    }
```

- [ ] **Step 2: Run the user-config test**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/codexExecutorDoesNotIgnoreUserConfigForWorkspaceWriteCommand
```

Expected: PASS. The existing `CodexExecutor` should already omit `--ignore-user-config`.

- [ ] **Step 3: If the test fails, remove only the unwanted argument**

If the test reports that `--ignore-user-config` is present, edit `leanring-buddy/CodexExecutor.swift` so `commandArguments(...)` never appends `--ignore-user-config`.

The `commandArguments(...)` method should keep this shape:

```swift
        if mode == .workspaceWrite {
            arguments += [
                "--ask-for-approval",
                "never"
            ]
        }

        arguments += ["exec"]
```

Expected: no `--ignore-user-config` appears anywhere in the argument list.

- [ ] **Step 4: Run the user-config test again**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS' -only-testing:leanring-buddyTests/leanring_buddyTests/codexExecutorDoesNotIgnoreUserConfigForWorkspaceWriteCommand
```

Expected: PASS.

- [ ] **Step 5: Commit the user-config assertion**

Run:

```bash
git add leanring-buddyTests/leanring_buddyTests.swift leanring-buddy/CodexExecutor.swift
git commit -m "test: assert Codex uses user config"
```

If `leanring-buddy/CodexExecutor.swift` did not change, omit it from `git add`.

### Task 4: Run The Focused Automated Test Suite

**Files:**
- Test: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Run all Lorelei unit tests**

Run:

```bash
xcodebuild test -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS'
```

Expected: PASS. Existing tests plus the new Computer Use tests should pass.

- [ ] **Step 2: If the scheme name is unavailable, list schemes and retry**

Run:

```bash
xcodebuild -list -project leanring-buddy.xcodeproj
```

Expected: output includes a buildable scheme. If the scheme is not `Lorelei`, rerun Step 1 with the listed app scheme.

- [ ] **Step 3: Commit any test-command fix if needed**

Only if the previous steps required a project or scheme fix, commit that fix:

```bash
git add leanring-buddy.xcodeproj/project.pbxproj
git commit -m "fix: stabilize Lorelei test scheme"
```

Expected: no commit is needed if tests run with the existing scheme.

### Task 5: Semi-Manual Local E2E Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Confirm Codex sees Computer Use MCP locally**

Run:

```bash
codex mcp list
```

Expected: output contains a row named `computer-use` with `Status` shown as `enabled`.

- [ ] **Step 2: Build Lorelei**

Run:

```bash
xcodebuild build -project leanring-buddy.xcodeproj -scheme Lorelei -destination 'platform=macOS'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Launch Lorelei**

Run:

```bash
open -a Lorelei
```

If that fails because the app is not installed, open the built product from Xcode's derived data or launch from Xcode.

Expected: Lorelei appears in the menu bar.

- [ ] **Step 4: Select a valid workspace in the Lorelei panel**

Use the Lorelei panel directory picker and select:

```text
/Users/taishi/Work/focus/projects/lorelei-3
```

Expected: the panel shows the selected workspace as valid.

- [ ] **Step 5: Trigger a Computer Use request by voice**

Hold the Lorelei push-to-talk shortcut and say:

```text
open the browser
```

Expected: Lorelei shows a pending confirmation titled `Run Codex computer-use action?`.

- [ ] **Step 6: Confirm the request in Lorelei**

Click the panel confirmation button.

Expected: Lorelei starts a `codex exec` run. If the request requires desktop UI operation, the Codex Computer Use overlay or operation should begin.

- [ ] **Step 7: Verify result reporting**

Expected:

- The Lorelei panel shows either Codex's final response or a clear failure message.
- Spoken feedback is only a short status such as `Done` or `Failed`.
- Lorelei does not create a commit.

- [ ] **Step 8: Record the E2E outcome in the final response**

Report:

- Whether `codex mcp list` showed `computer-use` enabled.
- Whether build succeeded.
- Whether Lorelei launched.
- Whether the voice-triggered confirmation appeared.
- Whether Codex Computer Use began after confirmation.

Do not commit anything for this task unless a source change was required.
