# Architecture

Lorelei is a voice-first macOS desktop assistant.
Hold a hotkey, speak, and on-device speech recognition hands the transcript to Codex (`codex app-server`), which drives the desktop through Lorelei's in-process `lorelei.*` dynamic tools.

This document orients contributors to the runtime pipeline, the three test seams, and the intentional extension point.
It is grounded in the code; if a detail is not here, prefer reading the named types over guessing.

## Pipeline

```
[hotkey hold] ──→ cursor capsule: liquid glass + live waveform
      │ release
      ▼
SpeechAnalyzer / DictationTranscriber (on-device STT, macOS 26)
      │ final transcript
      ▼
LoreleiCommandRouter (dictate / desktop action / ask / edit / workspace)
      │
      ▼
codex app-server subprocess (JSON-RPC 2.0 over stdio, model pinned to gpt-5.5)
      │ streams deltas, tool calls, approval requests → glass toolbar
      │ dynamic tool calls
      ▼
Lorelei.app executes in-process via lorelei.* tools:
  lorelei.foreground_app     bring an app or URL onscreen (handles Spaces)
  lorelei.desktop_snapshot   read the AX tree; elements get [eN] ids
  lorelei.desktop_action     press / focus / raise / open / select / showMenu by id
  lorelei.set_text           set text via AX values (IME-safe for non-ASCII)
  lorelei.screenshot         PNG fallback when the AX tree is not enough
  lorelei.memory_write       replace local profile or volatile memory Markdown
```

Hotkey capture and the floating UI live in the companion / toolbar layer.
`BuddyDictationManager` owns the listen → transcribe path through a `BuddyTranscriptionProvider`.
`CompanionManager` owns turn routing into Codex and the dynamic-tool handler that answers App Server tool calls.

## Three seams

Production code depends on protocols so tests never need a real microphone, a real `codex` process, or granted TCC permissions.

| Seam | Abstracts | Production implementation | Test stand-in |
|------|-----------|---------------------------|---------------|
| `BuddyTranscriptionProvider` | Streaming speech-to-text backends | `SpeechAnalyzerTranscriptionProvider` | No dedicated `Fake*` provider type today; factory coverage lives in `SpeechAndStoresTests`, and streaming-session fakes such as `RecordingTranscriptionSession` appear where audio plumbing is under test |
| `CodexAppServerTransporting` | JSON-RPC line transport over stdio | `CodexAppServerStdioTransport` | `FakeCodexAppServerTransport` (and related scripted transports in `LoreleiTests/TestSupport.swift`) |
| `DesktopActionExecuting` | AX snapshot, element actions, text setting, screenshots | `AXDesktopActionExecutor` | `FakeDesktopActionExecutor` |

New behavior that touches one of these surfaces should stay behind the protocol and extend the existing scripted-fake style.

## Dynamic tools: the extension point

The `lorelei.*` App Server dynamic tools are the extension point for desktop capability.
A separate plugin system is deliberately deferred; add tools here instead.

Declaration, routing, and execution:

1. **Declare** a `CodexAppServerDynamicToolSpec` (name + `lorelei` namespace + JSON Schema) in the matching suite:
   - Desktop AX tools: `CodexAppServerDesktopToolSuite.toolSpecs()`
   - Foreground / Spaces: `CodexAppServerDesktopForegroundTool.spec`
   - Memory: `CodexAppServerMemoryToolSuite.toolSpecs()`
2. **Register** the specs from `CompanionManager` when building the Codex turn (`dynamicToolSpecsResolver` concatenates foreground + desktop + memory specs).
3. **Route and execute** in the `dynamicToolHandler` closure:
   - `foreground_app` → `CodexAppServerDesktopForegroundTool.handle`
   - `memory_write` → `CodexAppServerMemoryToolSuite.handle`
   - other `lorelei.*` desktop tools → `CodexAppServerDesktopToolSuite.handle`, which calls into `DesktopActionExecuting`

Qualified names Codex sees are `lorelei.<tool>` (for example `lorelei.desktop_snapshot`).

## Desktop-action topology

Desktop-driving turns prefer the official Codex Computer Use plugin when ChatGPT.app has installed and enabled it.
Lorelei never bundles or redistributes that plugin; `ComputerUsePluginLocator` only discovers the ChatGPT-managed install.

If the plugin is missing, or the user sets the kill switch `defaults write dev.taishi.lorelei LoreleiComputerUseDisabled -bool true`, Lorelei falls back to the in-house `lorelei.*` accessibility tools backed by `AXDesktopActionExecutor`.

During a Computer Use action, interrupt with the plugin's own indicator / Esc, or Lorelei's Stop button.

## Text-input doctrine

Two paths insert text into other apps; neither synthesizes per-character content keystrokes.

- **Dictation / edit mode:** AX prepares the selection (`AXDictationTextReplacer`, `AXDictationSelectionEditor`); content lands through `DictationPasteInserter` (clipboard + Cmd+V).
  Synthesized content keystrokes corrupt IME input (Japanese in particular).
- **Desktop tool `lorelei.set_text`:** writes through accessibility values (`AXUIElementSetAttributeValue` on `kAXValueAttribute` / `kAXSelectedTextAttribute`) via `AXDesktopActionExecutor`.

Prefer the paste path for dictation-style insertion into rich / Electron editors; use `lorelei.set_text` when Codex is driving an AX-addressable field.

## Testing philosophy

The suite must stay runnable without a real Codex CLI, microphone, or permission grants.
Transcription, App Server protocol frames, and desktop actions are seams with scripted fakes.

Flakes are fixed deterministically: inject delays, clocks, and readiness gates in fakes (see `SystemDictationControllerTests`), do not paper over races with retries.
Suites that touch `UserDefaults` use a unique suite name and call `removePersistentDomain`.
Routing changes extend the matrix in `CommandRouterTests`.
