# Computer Use Via Codex Design

Date: 2026-05-27

## Goal

Make Lorelei able to trigger Codex app-style Computer Use from voice commands while keeping Lorelei focused as a voice-first Codex controller.

Lorelei should not become its own Computer Use runtime in this iteration. It should route voice commands into confirmed `codex exec` sessions that load the user's existing Codex configuration, including the enabled Computer Use plugin and MCP server.

## Non-Goals

- Do not implement a Swift MCP client.
- Do not call Computer Use tools directly from Lorelei.
- Do not add a large abstraction layer for a possible future direct Computer Use runtime.
- Do not automate real UI operation in unit tests.
- Do not allow Lorelei to auto-commit changes.

## Context

The current app already has the core path:

- `LoreleiCommandRouter` maps UI-operation phrases to `.codexComputerUse(prompt)`.
- `CompanionManager` requests panel confirmation before running Computer Use requests.
- `CodexPromptBuilder.computerUsePrompt(for:)` builds the Codex prompt.
- `CodexExecutor` runs `codex exec` and captures the final message for the panel.

The local Codex configuration already enables the `computer-use` MCP server through the Computer Use plugin. For this design, Lorelei should rely on that user configuration instead of vendoring or reimplementing plugin setup.

## Architecture

Lorelei remains a voice-first controller. It owns voice transcription, command routing, workspace selection, confirmation, status display, and short spoken feedback. Codex owns reasoning, MCP tool discovery, Computer Use safety policy, and actual UI operation.

The intended flow is:

```text
voice transcript
  -> LoreleiCommandRouter
  -> .codexComputerUse(prompt)
  -> CompanionManager panel confirmation
  -> CodexPromptBuilder.computerUsePrompt(for:)
  -> CodexExecutor.run(.workspaceWrite, ...)
  -> codex exec reads ~/.codex/config.toml
  -> Codex uses computer-use MCP when needed
  -> panel result + short spoken status
```

Lorelei should not pass `--ignore-user-config` for these requests, because the user's Codex config is the source of truth for enabled plugins and MCP servers.

## Minimal Future-Proofing

Future direct Computer Use support is not a main priority. The only future-proofing in scope is keeping the Computer Use prompt construction small and named, so the intent is clear.

Do not add a `ComputerUseExecutor`, MCP transport layer, plugin installer, or direct tool registry in this iteration.

## Prompt Requirements

The Computer Use prompt should tell Codex:

- Use the existing Codex Computer Use plugin when UI operation is needed.
- Follow Codex's Computer Use confirmation and safety policy for risky UI actions.
- Do not commit changes.
- Treat the user's voice transcript as the request.

The prompt should stay concise. Lorelei should not duplicate the full Computer Use policy text; Codex already loads that policy from the plugin skill/runtime context.

## Safety And Error Handling

Computer Use requests must always require Lorelei panel confirmation before `codex exec` runs.

After confirmation, Lorelei may run Codex with `--ask-for-approval never` because Lorelei has already collected the high-level user approval. Codex's own Computer Use policy still applies inside the session for risky UI actions such as destructive changes, credential handling, sensitive data transmission, financial actions, and account or system setting changes.

Expected failure cases:

- No workspace is selected.
- The selected workspace path is invalid.
- The Codex executable cannot be found.
- The user's Codex config does not expose the Computer Use plugin or MCP server.
- Codex exits nonzero.
- The request times out.

Lorelei should show detailed failure text in the panel and speak only the existing short status phrase, such as `Failed`.

## Testing

Keep automated tests small:

- Router maps UI-operation phrases to `.codexComputerUse`.
- `.codexComputerUse` requires confirmation.
- `CodexPromptBuilder.computerUsePrompt(for:)` mentions the existing Codex Computer Use plugin, follows Codex Computer Use safety policy, includes the original user request, and forbids commits.
- `CodexExecutor` command construction does not include `--ignore-user-config`.

Add a semi-manual local E2E check after implementation:

1. Build and launch Lorelei locally.
2. Select a valid workspace.
3. Trigger a Computer Use style request by voice, such as "open the browser" or "click the submit button".
4. Confirm the Lorelei panel prompt.
5. Verify `codex exec` starts and can see the `computer-use` MCP server from the user's Codex config.
6. Verify the Codex Computer Use overlay or UI operation begins when the request requires desktop interaction.
7. Verify Lorelei reports completion or failure in the panel and speaks only a short status.

Fully automated UI E2E is out of scope because it would require stable microphone input, macOS permission state, Codex app/plugin state, and real desktop UI operations. That belongs in a later reliability pass if Computer Use becomes a core shipping feature.
