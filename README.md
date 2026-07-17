# Lorelei

![CI](https://github.com/taishikato/lorelei/actions/workflows/ci.yml/badge.svg)

<img width="2560" height="1440" alt="Image" src="https://github.com/user-attachments/assets/5391ce6f-bdfd-4475-b0a9-42ac5d21923f" />

Lorelei is an open-source (MIT), local-first voice control layer for your Mac.
Hold a hotkey, speak, and on-device speech recognition hands the transcript to [OpenAI Codex](https://developers.openai.com/codex) (`codex app-server`, gpt-5.5), which drives the desktop through Lorelei's accessibility tools - using your existing ChatGPT subscription, with no separate API bill and no cloud middleman of Lorelei's own.

Everything happens through a small liquid-glass toolbar at the top of your screen and a waveform capsule next to your cursor.
There is no chat window to babysit.

## Modes

| Mode | Hotkey | What it does |
|------|--------|--------------|
| Desktop actions | Hold `Control + Option`, speak, release | Codex operates the Mac: opens apps, clicks UI, fills text, screenshots when needed |
| Dictate | Hold `Control + Shift`, speak, release | Raw transcript pastes into the frontmost app, then upgrades in place if still untouched |
| Edit | Select text, then hold `Control + Shift` and speak an instruction | Rewrites the selection in place (clipboard fallback if the selection moved) |
| Ask | Hold `Control + Option` and ask a question | Answers about the screen, or about the current selection without a screenshot |

See [Talking to Lorelei](#talking-to-lorelei) for the full reference, Stop / approval behavior, and kill-switch defaults.

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
| Codex runtime | ChatGPT for macOS with its bundled Codex CLI, or Codex CLI 0.142.x or later |
| Codex auth | Sign in to ChatGPT, or run `codex login` for a standalone CLI |

Lorelei talks to `codex app-server` over stdio.
When ChatGPT.app is installed, Lorelei prefers its bundled Codex CLI so both apps use the same OpenAI-distributed runtime.
An explicitly configured executable remains the highest-priority choice, and PATH, Homebrew, npm, and nvm Codex installations remain supported fallbacks.
The official Computer Use integration additionally requires the ChatGPT-managed plugin described below.

## Install and run

### Download

Download the latest signed and notarized DMG from [GitHub Releases](https://github.com/taishikato/lorelei/releases/latest).
It installs without a Gatekeeper warning; drag Lorelei to Applications.
Lorelei can also check for updates from Settings -> General -> Check for Updates.

### Build from source

```bash
git clone https://github.com/taishikato/lorelei.git
cd lorelei
open Lorelei.xcodeproj
```

Build and run the `Lorelei` scheme from Xcode (`Cmd+R`).
Debug builds are signed with your Apple Development certificate so that macOS permission grants survive rebuilds; select your own team in Signing settings on first build.

### First-run setup

Fresh installs walk through a first-run onboarding flow: welcome -> permissions -> workspace.
Afterwards, permissions and settings live in the Lorelei Settings window, opened from the gear button in the expanded floating toolbar.
The settings window also opens automatically if permissions go missing.

Lorelei needs these permissions and approvals, all granted to the single Lorelei app:

1. **Microphone** - to hear you.
2. **Accessibility** - to read UI trees and press buttons.
3. **Screen Recording** - for the screenshot fallback when an app exposes poor accessibility data.
4. **Screen Content Picker** - a one-time approval used by screen questions.

You also pick a **workspace folder** in onboarding or settings; Codex uses it as the working directory for file and shell commands.

### Talking to Lorelei

- Hold `Control + Option`, speak, release.
- Hold `Control + Shift`, speak, and release to dictate into the frontmost app.
  The raw transcript appears immediately, then Lorelei upgrades it in place when cleanup finishes only if the text is still untouched.
- Select text first and Lorelei switches to edit mode: hold `Control + Shift` and speak an instruction ('make this shorter', 'make it formal') and the selection is rewritten in place.
  If the selection changed while Codex was rewriting, the result lands on the clipboard instead.
- Commands like 'open …', 'click …', 'type …' become desktop actions.
- 'What's on my screen?' style questions capture the screen and answer.
  With text selected, questions like 'what does this mean?' are answered about the selection instead - no screenshot taken.
- Git and coding requests ('what changed?', 'update the readme') run through Codex against your workspace folder.
- Press **Stop** in the expanded toolbar to interrupt a run instantly.
- When Codex flags an action as risky, the toolbar auto-expands with Accept / Decline buttons and announces 'Needs approval'. That approval bridge is the only gate; routine commands run without confirmation.

To restore format-first dictation, run `defaults write dev.taishi.lorelei LoreleiDictationRawInsertFirstDisabled -bool true` and restart Lorelei.
To disable selection edit mode, run `defaults write dev.taishi.lorelei LoreleiEditModeDisabled -bool true` and restart Lorelei.
Electron apps (Slack, Claude, ChatGPT, VS Code, ...) keep their accessibility tree dormant by default; Lorelei enables it automatically (via Electron's `AXManualAccessibility`) the first time you dictate into one, so in-place cleanup and edit mode work there too.

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

### Computer Use

Lorelei prefers the official Codex Computer Use plugin for desktop actions when ChatGPT.app is installed and Computer Use has been enabled there at least once, so its helper and macOS permissions are available.
Lorelei never bundles or redistributes the proprietary plugin; it only points Codex at the installation managed by ChatGPT.app.
If the plugin is absent or unavailable, Lorelei automatically falls back to its in-house `lorelei.*` accessibility tools.
You can force that fallback with `defaults write dev.taishi.lorelei LoreleiComputerUseDisabled -bool true` and re-enable automatic selection with `defaults delete dev.taishi.lorelei LoreleiComputerUseDisabled`.
During a Computer Use action, use the plugin's on-screen indicator or Esc, or Lorelei's Stop button, to interrupt the run.

Design notes:

- **Official Computer Use is primary, with an in-house fallback.** Lorelei attaches ChatGPT.app's installed plugin only to desktop-action turns and keeps its own App Server dynamic tools available when the plugin cannot be used.
- **Text lands via clipboard paste; AX handles selection, never content.** Content keystroke simulation corrupts input through IMEs (Japanese in particular), and Electron rich editors silently drop AX text writes - so Lorelei selects the target range via accessibility and pastes through the app's normal input path.
- **The protocol layer tracks the installed Codex version.** Run `./scripts/update-appserver-schema.sh` after upgrading the CLI and review the schema diff against `CodexAppServerProtocol.swift`.

## Development

Docs live in the repo:

- PRD: [issue #2](https://github.com/taishikato/lorelei/issues/2)
- App Server schema snapshot: `docs/appserver-schema/` tracks the codex app-server JSON schema. Regenerate it with `./scripts/update-appserver-schema.sh` after Codex CLI upgrades, then review the diff against `CodexAppServerProtocol.swift`.

Run the tests:

```bash
xcodebuild test -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -test-timeouts-enabled YES -default-test-execution-time-allowance 60
```

CI runs the same suite on every PR.
The suite needs no real codex process, no microphone, and no granted permissions: transcription, the App Server protocol, and desktop actions are all seams with scripted fakes.
The three seams to know:

1. `BuddyTranscriptionProvider` - speech-to-text backends.
2. `CodexAppServerTransporting` - the JSON-RPC line transport (tests feed scripted frames).
3. `DesktopActionExecuting` - AX snapshots, element actions, text setting, screenshots.

## Contributing

Contributions are welcome under the [MIT License](LICENSE).
Start with [CONTRIBUTING.md](CONTRIBUTING.md) for build / test expectations and project conventions, and [ARCHITECTURE.md](ARCHITECTURE.md) for the runtime pipeline and extension points.

## Known limitations

- **English only for now.** Japanese speech is currently mis-transcribed as English phonetics; ja-JP model installation and locale selection are planned follow-ups.
- One active turn at a time; no session history UI and no text input in the toolbar (deliberate v1 scope).
- Apps with poor accessibility support depend on the screenshot fallback, which is slower and less precise.
- Official Computer Use availability depends on ChatGPT.app's managed plugin layout; Lorelei falls back automatically if discovery fails after an update.

## Privacy

- Audio never leaves your Mac; transcription is fully on-device.
- Transcripts, accessibility-tree text, and screenshots taken by `lorelei.screenshot` are sent to OpenAI through your Codex account, subject to its data controls.
- Release builds send anonymous usage stats (event names, counts, durations) to PostHog so I can see what's used; never transcripts, screen content, or file paths. Debug builds send nothing.

## Acknowledgements

Lorelei started from [farzaa/clicky](https://github.com/farzaa/clicky) codebase.
