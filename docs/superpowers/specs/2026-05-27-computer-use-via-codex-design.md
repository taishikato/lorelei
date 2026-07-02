# Computer Use Via Codex Design

Date: 2026-05-27

## Supersession Note

The original `codex exec` approach is superseded for Computer Use. Direct testing showed that non-interactive `codex exec` cannot reliably carry Computer Use / Chrome approval and user-input prompts back to Lorelei. Computer Use now needs an interactive Codex App Server control plane.

URL and app opening are part of the same desktop-control surface. Lorelei should not keep a caller-side `/usr/bin/open` escape hatch, even for simple URL opens, because that creates a second execution path with different approval, logging, and cancellation behavior. If `/usr/bin/open` is the right primitive, Codex should run it inside a Codex App Server turn.

## Goal

Make Lorelei able to trigger Codex app-style desktop control from voice commands while keeping Lorelei focused as a voice-first Codex controller.

Lorelei should not become its own Computer Use runtime in this iteration. It should route desktop-control commands into confirmed Codex App Server turns. This includes simple deterministic desktop actions such as opening a URL in Chrome, plus richer visual UI operation such as clicking, typing, scrolling, dragging, or reading the screen.

## Non-Goals

- Do not implement a Swift MCP client.
- Do not call Computer Use tools directly from Lorelei.
- Do not add a large abstraction layer for a possible future direct Computer Use runtime.
- Do not automate real UI operation in unit tests.
- Do not allow Lorelei to auto-commit changes.

## Context

The current app has two relevant paths:

- Workspace/read-only requests still use `CodexExecutor` and non-interactive `codex exec`.
- Desktop-control requests use `LoreleiCommandRouter`, `CompanionManager`, `CodexPromptBuilder.desktopActionPrompt(for:)`, and `CodexAppServerExecutor`.

The local Codex configuration may enable browser, Chrome, Computer Use, and other plugins. For this design, Lorelei should rely on Codex App Server as the control plane instead of vendoring or reimplementing plugin setup. Lorelei should only hold a small protocol client for the App Server messages it needs to start turns, display approval requests, answer approvals, and collect the final result.

## Architecture

Lorelei remains a voice-first controller. It owns voice transcription, command routing, workspace selection, confirmation, status display, and short spoken feedback. Codex owns reasoning, MCP tool discovery, Computer Use safety policy, and actual UI operation.

The intended flow is:

```text
voice transcript
  -> LoreleiCommandRouter
  -> .codexDesktopAction(prompt)
  -> CompanionManager panel confirmation
  -> CodexPromptBuilder.desktopActionPrompt(for:)
  -> CodexAppServerExecutor.runDesktopAction(...)
  -> codex app-server --listen stdio://
  -> Codex runs the smallest suitable action inside the App Server turn
  -> App Server requests are bridged back to the Lorelei panel
  -> panel result + short spoken status
```

For simple app or URL opening, Codex should first call Lorelei's App Server dynamic foregrounding tool. If a local primitive such as `/usr/bin/open` is ever useful, it must still run inside the App Server turn. For visual UI tasks, Codex may use the Computer Use plugin. Lorelei should not run local desktop-control commands directly.

## Minimal Future-Proofing

Future direct Computer Use support is not a main priority. The only future-proofing in scope is keeping the desktop-action prompt construction small and named, so the intent is clear.

Do not add a `ComputerUseExecutor`, MCP transport layer, plugin installer, or direct tool registry in this iteration.

## Prompt Requirements

The desktop-action prompt should tell Codex:

- Use Codex App Server's interactive control plane for every desktop operation, including app and URL opening.
- For app or URL opening, first call `lorelei.foreground_app`; URL opening must also go through that tool.
- Use the Codex Computer Use plugin only when visual UI inspection, clicking, typing, scrolling, dragging, or key presses are actually needed.
- Before Computer Use inspects a desktop app, call `lorelei.foreground_app` for that target app. If Computer Use reports `cgWindowNotFound`, call the foregrounding tool once more before retrying visual inspection.
- Follow Codex's Computer Use confirmation and safety policy for risky UI actions.
- Do not rely on caller-side local shortcuts.
- Do not commit changes.
- Treat the user's voice transcript as the request.

The prompt should stay concise. Lorelei should not duplicate the full Computer Use policy text; Codex already loads that policy from the plugin skill/runtime context.

## Safety And Error Handling

Desktop-control requests must always require Lorelei panel confirmation before a Codex App Server turn runs.

After confirmation, Lorelei should keep bridging App Server approval requests back to the panel. This covers command execution, file changes, permission requests, tool user-input prompts, and MCP elicitations. Codex's own Computer Use policy still applies inside the session for risky UI actions such as destructive changes, credential handling, sensitive data transmission, financial actions, and account or system setting changes.

Expected failure cases:

- No workspace is selected.
- The selected workspace path is invalid.
- The Codex executable cannot be found.
- Codex App Server cannot start.
- Codex App Server requests a client method Lorelei does not support yet.
- Codex App Server closes before starting or completing a turn.
- The request times out.
- Codex App Server reports `waitingOnApproval`, but no approval request is delivered to the client. Lorelei should report this separately from a generic timeout.
- Computer Use returns `cgWindowNotFound` because the target app has no normal capturable window in the current on-screen Space.

Lorelei should show detailed failure text in the panel and speak only the existing short status phrase, such as `Failed`.

## Testing

Keep automated tests small:

- Router maps UI-operation phrases and Chrome URL opening to `.codexDesktopAction`.
- `.codexDesktopAction` requires confirmation.
- `CodexPromptBuilder.desktopActionPrompt(for:)` requires App Server for every desktop operation, requires `lorelei.foreground_app` for app and URL opening, scopes Computer Use plugin usage to visual UI operation, includes the original user request, and forbids commits.
- `WorkspaceCommandExecutor` does not run desktop actions locally.
- `CodexAppServerProtocol` matches generated protocol shapes for initialize, initialized, thread/start, turn/start, turn/completed, and approval requests.
- `CodexAppServerExecutor` starts a thread, starts a turn, answers approval requests, and returns the final assistant message.

Add a semi-manual local E2E check after implementation:

1. Build and launch Lorelei locally.
2. Trigger a desktop-control request by voice, such as "open chatgpt.com in a new tab on Chrome" or "click the submit button".
3. Confirm the Lorelei panel prompt.
4. Verify `codex app-server --listen stdio://` starts.
5. Verify simple URL opening happens through the App Server turn, not through a caller-side local shortcut.
6. Verify the Codex Computer Use overlay or UI operation begins when the request requires visual desktop interaction.
7. Verify Lorelei reports completion or failure in the panel and speaks only a short status.

Fully automated UI E2E is out of scope because it would require stable microphone input, macOS permission state, Codex app/plugin state, and real desktop UI operations. That belongs in a later reliability pass if Computer Use becomes a core shipping feature.

## Local Verification Notes 2026-05-28

Unit coverage now verifies that Lorelei routes desktop actions through Codex App Server, disables the Chrome plugin for desktop actions, enables the Computer Use plugin, attaches the Computer Use skill input, registers `lorelei.foreground_app`, bridges command/file/tool/MCP/permissions approvals, reports failed MCP tool calls even when the turn completes, and distinguishes an undelivered approval request from a generic timeout.

Live App Server smoke tests showed the App Server route is being used: `codex app-server --listen stdio://` starts, `thread/start` registers `lorelei.foreground_app`, the model calls that dynamic tool, and `https://chatgpt.com` opens in Google Chrome through the App Server turn. No caller-side desktop shortcut is needed for that path.

The remaining reliability work is true visual UI operation beyond foregrounding, such as clicking and typing after the target app is visible. That path should reuse the same App Server turn and foregrounding tool, then let the Computer Use plugin perform visual inspection and UI actions.
