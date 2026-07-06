# Lorelei

Lorelei is a voice buddy that lives on your macOS desktop and drives your computer through [OpenAI Codex](https://developers.openai.com/codex).
Hold a hotkey, say what you want, and Codex (gpt-5.5) operates your Mac for you: it reads the frontmost app's accessibility tree, clicks buttons, fills in text, and falls back to screenshots when it needs to see the screen.

Everything happens through a small liquid-glass toolbar at the top of your screen and a waveform capsule next to your cursor.
There is no chat window to babysit.

## What it looks like

- Hold `Control + Option` and speak. A glass capsule with a live waveform appears next to your cursor while Lorelei listens.
- Release the key. Your words are transcribed fully on-device and sent to Codex immediately. No confirmation dialog.
- A glass capsule at the top-center of your screen shows live status: `Ready`, `Listening…`, `Transcribing…`, the tool currently running, or `Needs approval`.
- Click the capsule to expand it: you see the live response stream, current tool activity, a Stop button, and approval buttons when Codex asks for one.
- Completion and failure are announced with a sound cue and a one-sentence spoken summary.

Example: say 'Open TextEdit and type hello world', and Lorelei foregrounds TextEdit, reads its accessibility tree, creates a document if needed, and types the text, narrating its progress in the toolbar stream.

## Requirements

| Requirement | Version |
|-------------|---------|
| macOS | 26 (Tahoe) or later, Apple Silicon |
| Xcode (to build) | 26 or later |
| Codex CLI | 0.142.x (`npm install -g @openai/codex`) |
| Codex auth | `codex login` (ChatGPT account) |

Lorelei talks to `codex app-server` over stdio, so the Codex CLI must be installed and logged in before Lorelei can run commands.

## Install and run

There is no packaged release yet; you build from source.

```bash
git clone https://github.com/taishikato/lorelei.git
cd lorelei
open Lorelei.xcodeproj
```

Build and run the `Lorelei` scheme from Xcode (`Cmd+R`).
Debug builds are signed with your Apple Development certificate so that macOS permission grants survive rebuilds; select your own team in Signing settings on first build.

### First-run setup

Lorelei needs three permissions, all granted to the single Lorelei app:

1. **Microphone** - to hear you.
2. **Accessibility** - to read UI trees and press buttons.
3. **Screen Recording** - for the screenshot fallback when an app exposes poor accessibility data.

The setup panel (menu bar icon) shows a Grant button for each, plus a one-time screen-content picker approval used by screen questions.
You also pick a **workspace folder** there; Codex uses it as the working directory for file and shell commands.

### Talking to Lorelei

- Hold `Control + Option`, speak, release.
- Commands like 'open …', 'click …', 'type …' become desktop actions.
- 'What's on my screen?' style questions capture the screen and answer.
- Git and coding requests ('what changed?', 'update the readme') run through Codex against your workspace folder.
- Press **Stop** in the expanded toolbar to interrupt a run instantly.
- When Codex flags an action as risky, the toolbar auto-expands with Accept / Decline buttons and announces 'Needs approval'. That approval bridge is the only gate; routine commands run without confirmation.

## How it works

```
[hotkey hold] ──→ cursor capsule: liquid glass + live waveform
      │ release
      ▼
SpeechAnalyzer / DictationTranscriber (on-device STT, macOS 26)
      │ final transcript
      ▼
codex app-server subprocess (JSON-RPC 2.0 over stdio, model pinned to gpt-5.5)
      │ streams deltas, tool calls, approval requests → glass toolbar
      │ dynamic tool calls
      ▼
Lorelei.app executes in-process:
  lorelei.foreground_app     bring an app or URL onscreen (handles Spaces)
  lorelei.desktop_snapshot   read the AX tree; elements get [eN] ids
  lorelei.desktop_action     press / focus / raise an element by id
  lorelei.set_text           set text via AX values (IME-safe, required for non-ASCII)
  lorelei.screenshot         PNG fallback when the AX tree is not enough
```

Design notes:

- **Computer use is built in-house.** The official Codex computer-use plugin is desktop-app-only, so Lorelei registers its own desktop tools as App Server dynamic tools on the same JSON-RPC connection. No extra processes, no sockets, and every macOS permission stays attached to the one app bundle.
- **Text is typed via accessibility values, never simulated keystrokes.** Keystroke simulation corrupts input through IMEs (Japanese in particular).
- **The protocol layer tracks the installed Codex version.** Run `./scripts/update-appserver-schema.sh` after upgrading the CLI and review the schema diff against `CodexAppServerProtocol.swift`.

## Development

Docs live in the repo:

- Product spec and decision log: `docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md`
- Per-phase implementation plans: `docs/superpowers/plans/`
- PRD: [issue #2](https://github.com/taishikato/lorelei/issues/2)

Run the tests:

```bash
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS'
```

The suite needs no real codex process, no microphone, and no granted permissions: transcription, the App Server protocol, and desktop actions are all seams with scripted fakes.
The three seams to know:

1. `BuddyTranscriptionProvider` - speech-to-text backends.
2. `CodexAppServerTransporting` - the JSON-RPC line transport (tests feed scripted frames).
3. `DesktopActionExecuting` - AX snapshots, element actions, text setting, screenshots.

## Known limitations

- **English only for now.** Japanese speech is currently mis-transcribed as English phonetics; ja-JP model installation and locale selection are planned follow-ups.
- One active turn at a time; no session history UI and no text input in the toolbar (deliberate v1 scope).
- Apps with poor accessibility support depend on the screenshot fallback, which is slower and less precise.
- Codex computer use may land officially in the App Server someday ([openai/codex#20851](https://github.com/openai/codex/issues/20851)); Lorelei'd evaluate switching.

## Privacy

- Audio never leaves your Mac; transcription is fully on-device.
- Transcripts, accessibility-tree text, and screenshots taken by `lorelei.screenshot` are sent to OpenAI through your Codex account, subject to its data controls.

## Acknowledgements

Lorelei started from [farzaa/clicky](https://github.com/farzaa/clicky) codebase.
