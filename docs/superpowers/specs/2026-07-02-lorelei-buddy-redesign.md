# Lorelei Buddy Redesign - Design Spec (2026-07-02)

PRD: https://github.com/taishikato/lorelei/issues/2
This spec records the decisions from the 2026-07-02 design interview and the research that informed them.
It is the source of truth for the per-phase implementation plans.

## Concept

Lorelei is a resident macOS voice buddy wrapping the Codex App Server.
Hold a hotkey, speak, and Codex (gpt-5.5) operates the desktop through Lorelei's own AX-tree computer-use tools.
A floating liquid-glass toolbar shows status and the live stream; a cursor-side glass capsule shows the waveform while listening.

## Architecture

```
[hotkey hold] ──→ [cursor capsule: liquid glass + live waveform]
      │ release
      ▼
[SpeechDetector + DictationTranscriber (on-device, macOS 26)]
      │ finalized text
      ▼
[codex app-server subprocess (stdio JSONL, JSON-RPC 2.0, gpt-5.5)]
      │ turn/start ── streams: item/agentMessage/delta, tool activity, requestApproval
      │ MCP tool calls
      ▼
[MCP stdio shim] ──local socket──→ [Lorelei.app: DesktopActionExecuting]
                                     ├ AX tree read / element action / AX-value text (IME-safe)
                                     ├ screenshot (ScreenCaptureKit)
                                     └ all TCC permissions live on Lorelei.app only
```

## Decisions

| # | Decision |
|---|----------|
| 1 | Base on PR #1; merge it, then evolve (App Server integration and approval bridging are kept). |
| 2 | Floating glass toolbar at top of screen (Dynamic Island style); menu bar item shrinks to settings/quit. |
| 3 | Hold-type push-to-talk only (existing CGEvent tap monitor); no toggle mode in v1. |
| 4 | No Lorelei-side confirmation: transcribed commands execute immediately; existing confirmation flow is removed. |
| 5 | Codex App Server approval bridging stays as the only gate (accept/decline from the toolbar). |
| 6 | Cursor-side indicator: small liquid-glass capsule with live waveform only; follows the cursor; no transcript there. |
| 7 | Computer use is built in-house: AX tree is fed to the model, actions address elements by ID (official Codex computer use is desktop-app-only; watch openai/codex#20851). |
| 8 | MCP tools are a thin stdio shim relaying over a local socket to Lorelei.app, which executes everything; TCC permissions are unified on the app bundle. |
| 9 | STT: SpeechDetector + DictationTranscriber only, on-device; delete OpenAI cloud STT and the old SFSpeechRecognizer implementation; keep the provider protocol as the seam. |
| 10 | Toolbar expanded view: current turn stream + tool activity + stop + approval UI only; no history, no text input in v1. |
| 11 | Sound cues (listen start/stop, done, fail, approval) + one-sentence TTS on completion/failure/approval. |
| 12 | Rename everything to Lorelei first; delete clicky-era analytics; keep THIRD_PARTY_NOTICES attribution. Bundle ID is already `dev.taishi.lorelei`, so no TCC reset. |
| 13 | Remove Chrome-specific routing (CDP preflight, Memory Saver wake, browser-open command type). Reintroduce only as model-selectable `browser_*` MCP tools if browser success rate is noticeably poor; never as router branching. |
| 14 | Screenshot fallback tool ships from the start (Screen Recording permission requested up front). |
| 15 | Delivery: merge PR #1, then small PRs per phase; each phase builds and passes tests before merge. |

Technical decisions made by the planner:

- Minimum OS: macOS 26 (Tahoe); toolchain Xcode 26. Required by liquid glass APIs and SpeechAnalyzer.
- App Server transport: stdio JSONL (WebSocket transport is experimental); regenerate protocol types with `codex app-server generate-json-schema` when upgrading the CLI.
- Model: gpt-5.5, set per-turn.
- Text input into apps MUST use AX value setting, not simulated keystrokes (Japanese IME corruption).

## Roles

- Fable 5: planner, manager, reviewer.
- Codex (gpt-5.5 via the Codex plugin): implementer.

## Phases

| Phase | Scope | Plan |
|-------|-------|------|
| 1 | Merge PR #1; rename to Lorelei; delete ClickyAnalytics and OpenAI STT provider; bump deployment target to 26.0 | `docs/superpowers/plans/2026-07-02-phase-1-merge-rename-cleanup.md` |
| 2 | App Server stdio migration; schema generation; remove confirmation flow and Chrome routing; single execution path | written at phase start |
| 3 | Computer use: `DesktopActionExecuting` seam, MCP shim + socket relay, AX executor, screenshot tool | written at phase start |
| 4 | Floating glass toolbar (collapsed status + expanded stream/stop/approval) | written at phase start |
| 5 | Cursor capsule waveform + sound cues + TTS summaries | written at phase start |
| 6 | STT migration to SpeechDetector + DictationTranscriber | written at phase start |

## Test seams

1. Transcription provider protocol (existing) - fake provider injects utterances.
2. Codex App Server JSON-RPC boundary (from PR #1) - scripted frames drive state transitions; no real codex process.
3. `DesktopActionExecuting` (new) - fake executor asserts tool calls become the right desktop-action requests.

UI stays a thin renderer of companion-manager state; minimal UI tests.

## Research summary (2026-07)

- Official Codex computer use (2026-04): desktop-app-only plugin, AX-tree based, best-in-class quality; no App Server/CLI exposure; openai/codex#20851 is the open request. Known Japanese IME typing bug.
- App Server: JSON-RPC 2.0 over stdio (default) / WebSocket (experimental) / Unix socket; thread/turn lifecycle; `turn/steer`, `turn/interrupt`; server-to-client approval requests; no protocol version guarantee - generate schemas per installed version.
- Speech: SpeechAnalyzer family (macOS 26) is current; DictationTranscriber fits short commands; ~2.2x faster than Whisper Large V3 Turbo at parity accuracy; fully on-device.

## Risks

- AX quality varies per app: screenshot fallback mitigates; sensitive-app exclusion is a v2 item.
- App Server protocol drift: absorbed by schema regeneration; pin the codex CLI version in docs when phases land.
- If official computer use reaches App Server, plan a migration and retire the in-house executor where it wins.
