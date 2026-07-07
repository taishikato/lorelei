# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

Lorelei is a voice-triggered macOS desktop buddy.
Hold Ctrl+Option, speak, and on-device speech recognition hands the transcript to Codex (`codex app-server`, model gpt-5.5), which drives the desktop through Lorelei's accessibility-tree dynamic tools.
macOS 26+, Swift/SwiftUI.

## Agent roles

- The main-loop model (Claude, Fable 5) is the planner, manager, and reviewer.
  It does not implement substantial code itself.
- Implementation is delegated to Codex gpt-5.5 through the codex plugin's official path (the `codex:codex-rescue` subagent or `/codex:rescue`), never raw `codex exec` via Bash.
- Execute contract: the reviewer creates an isolated worktree (`git worktree add .claude/worktrees/exec-NNN -b <branch>`) and hands Codex the path.
  Codex edits only inside it and skips commits, builds, and tests (its sandbox blocks .git writes, testmanagerd, and SPM network access).
  The reviewer runs every verification gate, commits in the worktree, reviews the full diff, and renders the verdict.
- The stop-time review gate (`/codex:setup`) is enabled for this repo.

## Build and test

```bash
xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug \
  -derivedDataPath DerivedData build

xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```

CI (`.github/workflows/ci.yml`) runs the same suite on every PR.
Before merging behavior changes, run the suite 3 times locally to catch flakiness.
If a test flakes, fix it even if it is unrelated to your change - usually by raising knife-edge timer margins, not by retrying.

## Testing conventions

- The suite needs no real codex process, microphone, or permissions.
  Transcription, the App Server protocol, and desktop actions are seams with scripted fakes (see `FakeCodexAppServerTransport` and friends in `LoreleiTests`).
- Every suite that touches UserDefaults uses a unique suite name plus `removePersistentDomain`.
- New behavior gets tests in the same style; routing changes extend the router matrix test.

## Code conventions

- Wrap every SwiftUI button and menu action in `deferredAction { ... }`.
  Direct actions that tear down the view subtree crash in `MainActor.assumeIsolated`.
- Text input into other apps goes through AX `setValue`, never synthesized keystrokes (Japanese IME breaks otherwise).
- The bundle ID `dev.taishi.lorelei` must never change - all TCC permissions (mic, accessibility, screen recording) are granted to it.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`: new files under `Lorelei/` and `LoreleiTests/` are picked up automatically, so do not edit `project.pbxproj` to add files.
- Analytics (`LoreleiAnalytics.swift`) carry only coarse metadata - never transcripts, conversation text, screen content, or file paths.
  A unit test pins the event names; keep it updated.
- No confirmation dialogs before executing voice commands.
  Codex approval bridging and the stop button are the safety valves.

## Style

- Commit messages in English, ending with the Co-Authored-By trailer for the agent.
- Plain dash '-', never the em dash.
- Use ' for quotes in prose and UI copy.

## Repo layout notes

- `docs/` is local-only (gitignored) except `docs/appserver-schema/`, the tracked codex app-server JSON schema snapshot.
  Regenerate it with `./scripts/update-appserver-schema.sh` after codex CLI upgrades and review the diff against `CodexAppServerProtocol.swift`.
- `plans/` is local-only (gitignored) - implementation plans and their status index.
- Releases: bump `MARKETING_VERSION`, run `./scripts/release.sh` (signs, notarizes, staples a DMG into `dist/`), tag `v<version>`, publish via `gh release create`.
