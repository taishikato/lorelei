# Phase 3: In-house Computer Use via Dynamic Tools - Implementation Plan

> **For agentic workers:** This plan is executed by Codex (gpt-5.5) task-by-task, reviewed by the planner between tasks. Steps use checkbox (`- [ ]`) syntax. Codex must not run git commands that write; the reviewer stages and commits. Codex builds with `-derivedDataPath ./DerivedData build-for-testing`; the reviewer runs tests.

**Goal:** Give gpt-5.5 real desktop control through Lorelei's own AX-tree tools - snapshot, element actions, IME-safe text setting, and screenshot fallback - registered as App Server dynamic tools, replacing the desktop-app-only `computer-use@openai-bundled` plugin.

**Architecture (revised from spec decision #8, approved 2026-07-03):** No MCP shim and no socket. Dynamic tools ride the existing app-server JSON-RPC connection: registered in `thread/start` `dynamicTools`, delivered as `item/tool/call`, executed in the Lorelei.app process (TCC stays unified naturally), answered via `dynamicToolCallResponse`. `lorelei.foreground_app` already proves this path. The `DesktopActionExecuting` seam from the spec is unchanged: the tool suite translates tool calls into seam requests; the AX implementation lives behind it.

**Tech Stack:** ApplicationServices AX APIs (`AXUIElement`), existing `CompanionScreenCaptureUtility` (ScreenCaptureKit), Swift Testing, App Server dynamic tools (schema: `docs/appserver-schema/DynamicToolCallResponse.json` - content items support `inputText` and `inputImage`/`imageUrl`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-02-lorelei-buddy-redesign.md`, decisions #7, #8 (as revised above), #14. Text into apps MUST use AX value setting, never keystroke simulation (Japanese IME).
- Tool namespace is `lorelei`; tool names: `desktop_snapshot`, `desktop_action`, `set_text`, `screenshot` (plus the existing `foreground_app`).
- `lorelei.foreground_app` and its tests stay untouched.
- All tool handling is `@MainActor` (matches `CodexAppServerDynamicToolHandler`).
- Build: `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -destination 'platform=macOS' -derivedDataPath ./DerivedData build-for-testing`
- Reviewer test command: `xcodebuild test ... -skip-testing:LoreleiUITests -test-timeouts-enabled YES -default-test-execution-time-allowance 60`
- Commit messages in English; one commit per task by the reviewer.

---

### Task 1: Desktop action seam + tool suite (snapshot / action / set_text)

**Files:**
- Create: `Lorelei/DesktopActionExecuting.swift`
- Create: `Lorelei/CodexAppServerDesktopToolSuite.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Produces (the seam - later tasks and tests depend on these exact shapes):

```swift
/// A snapshot line tree of the target app's AX elements, plus the IDs handed out.
struct DesktopSnapshotResult: Equatable, Sendable {
    let text: String            // compact indented tree, see format below
    let elementCount: Int
}

enum DesktopElementAction: String, Equatable, Sendable {
    case press      // AXPress
    case focus      // set AXFocused
    case raise      // AXRaise
}

enum DesktopSetTextMode: String, Equatable, Sendable {
    case replace
    case insert     // insert at current selection via AXSelectedText
}

struct DesktopActionOutcome: Equatable, Sendable {
    let success: Bool
    let message: String
}

@MainActor
protocol DesktopActionExecuting: AnyObject {
    /// appName nil = frontmost app. Assigns fresh element IDs (e1, e2, ...).
    func snapshot(appName: String?) async -> Result<DesktopSnapshotResult, DesktopActionError>
    func perform(_ action: DesktopElementAction, elementID: String) async -> DesktopActionOutcome
    func setText(_ text: String, elementID: String, mode: DesktopSetTextMode) async -> DesktopActionOutcome
    /// PNG data of the frontmost screen content (Task 2 wires this into a tool).
    func screenshot() async -> Result<Data, DesktopActionError>
}

enum DesktopActionError: Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case appNotFound(String)
    case staleElementID(String)
    case captureFailed(String)

    var toolMessage: String { ... } // e.g. staleElementID -> "Unknown or stale elementId 'e9'. Call lorelei.desktop_snapshot again before acting."
}
```

- Produces: `enum CodexAppServerDesktopToolSuite` with
  `static func toolSpecs() -> [CodexAppServerDynamicToolSpec]` (the three specs with JSON input schemas) and
  `static func handle(_ request: CodexAppServerDynamicToolCallRequest, executor: any DesktopActionExecuting) async -> CodexAppServerDynamicToolCallResult`.
- Consumes: `CodexAppServerDynamicToolSpec/CallRequest/CallResult`, `CodexAppServerJSONValue` (`CodexAppServerProtocol.swift:46-75`).

Snapshot text format (locked by tests; produced by the serializer in Task 3):

```
[e1] AXWindow "Untitled - TextEdit" (0,25 1024x743)
  [e2] AXTextArea value="Hello wor…" focused
  [e3] AXButton "Save" disabled
```

- [ ] **Step 1: Write failing tests.** Fake executor + suite behavior:

```swift
@MainActor
final class FakeDesktopActionExecutor: DesktopActionExecuting {
    var snapshotResult: Result<DesktopSnapshotResult, DesktopActionError> =
        .success(DesktopSnapshotResult(text: "[e1] AXWindow \"Demo\" (0,0 100x100)", elementCount: 1))
    var performCalls: [(DesktopElementAction, String)] = []
    var setTextCalls: [(String, String, DesktopSetTextMode)] = []
    var outcome = DesktopActionOutcome(success: true, message: "ok")
    var screenshotResult: Result<Data, DesktopActionError> = .success(Data([0x89, 0x50]))
    // protocol methods record arguments and return the stubs
}
```

Tests (names locked):
- `desktopToolSuiteRegistersSnapshotActionAndSetTextSpecs` - three specs, namespace `lorelei`, names as in Global Constraints, each `inputSchema` declares its required fields (`desktop_action`: `elementId` + `action` enum press/focus/raise; `set_text`: `elementId` + `text` + optional `mode`).
- `desktopToolSuiteSnapshotReturnsTreeText` - handle a `desktop_snapshot` call (arguments `{}` and `{"app":"TextEdit"}`), fake returns tree text, result success with that text; the `app` argument reaches the fake as `appName`.
- `desktopToolSuiteActionResolvesElementAndReportsOutcome` - `desktop_action` with `{"elementId":"e2","action":"press"}` records `(.press, "e2")`.
- `desktopToolSuiteSetTextDefaultsToReplaceMode` - `set_text` without `mode` records `.replace`; with `"mode":"insert"` records `.insert`.
- `desktopToolSuiteReportsStaleElementAsToolFailure` - fake outcome `success:false`/stale message surfaces as `success == false` and the message text.
- `desktopToolSuiteRejectsUnknownToolName` - unknown tool -> `success == false`, message mentions the tool name.

- [ ] **Step 2: Verify they fail to compile** (types missing) via build-for-testing.

- [ ] **Step 3: Implement** `DesktopActionExecuting.swift` (types above, with `toolMessage` strings) and `CodexAppServerDesktopToolSuite.swift`. Argument parsing goes through `CodexAppServerJSONValue` pattern matching; missing/invalid arguments return `success:false` with a corrective message (never throw). Keep the suite free of AX imports - it only talks to the seam.

- [ ] **Step 4: build-for-testing green; reviewer runs tests; reviewer commits** (`feat: add desktop action seam and dynamic tool suite`).

---

### Task 2: Image results + lorelei.screenshot tool

**Files:**
- Modify: `Lorelei/CodexAppServerProtocol.swift` (`CodexAppServerDynamicToolCallResult` ~61, `dynamicToolCallResponse` ~385)
- Modify: `Lorelei/CodexAppServerDesktopToolSuite.swift` (add the fourth spec + handler arm)
- Modify: `Lorelei/CodexAppServerDesktopForegroundTool.swift` + any other `CodexAppServerDynamicToolCallResult(success:contentText:)` call sites (keep compiling via the convenience init)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Produces:

```swift
enum CodexAppServerDynamicToolContentItem: Equatable, Sendable {
    case text(String)
    case image(dataURL: String)   // "data:image/png;base64,...."
}

struct CodexAppServerDynamicToolCallResult: Equatable, Sendable {
    let success: Bool
    let contentItems: [CodexAppServerDynamicToolContentItem]

    init(success: Bool, contentItems: [CodexAppServerDynamicToolContentItem]) { ... }
    /// Convenience kept so existing call sites (foreground tool, executor default handler) do not change shape.
    init(success: Bool, contentText: String) { self.init(success: success, contentItems: [.text(contentText)]) }
}
```

- `dynamicToolCallResponse` maps `.text` -> `{"type":"inputText","text":...}` and `.image` -> `{"type":"inputImage","imageUrl":...}` per `docs/appserver-schema/DynamicToolCallResponse.json`.

- [ ] **Step 1: Failing tests:**
- `dynamicToolCallResponseEncodesImageContentItems` - a result with `[.text("done"), .image(dataURL: "data:image/png;base64,AA==")]` produces `contentItems` `[{type:inputText,text:done},{type:inputImage,imageUrl:data:...}]`.
- `desktopToolSuiteScreenshotReturnsImageItem` - `screenshot` call on the suite with the fake's PNG data returns success and one `.image` whose dataURL starts with `data:image/png;base64,`.
- `desktopToolSuiteScreenshotFailureIsToolFailure` - fake `.failure(.captureFailed("no permission"))` -> `success == false`, text mentions the message.

- [ ] **Step 2: Red via build-for-testing, then implement.** Screenshot spec description must tell the model this is the fallback when the AX snapshot is insufficient (canvas/electron apps), not the primary path.

- [ ] **Step 3: build-for-testing green; reviewer runs tests + commits** (`feat: add screenshot tool with image content results`).

---

### Task 3: AX executor implementation

**Files:**
- Create: `Lorelei/AXDesktopActionExecutor.swift`
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Consumes: the seam from Task 1; `CompanionScreenCaptureUtility` for screenshot capture; `WindowPositionManager.hasAccessibilityPermission()` for the permission check.
- Produces:

```swift
/// Value tree decoupled from AX so serialization/registry are unit-testable.
struct DesktopUINode: Equatable, Sendable {
    let role: String                 // e.g. "AXButton"
    let title: String?               // AXTitle or AXDescription or AXLabel, first non-empty
    let value: String?               // AXValue stringified
    let frame: CGRect?
    let isEnabled: Bool
    let isFocused: Bool
    let children: [DesktopUINode]
}

@MainActor
final class AXDesktopActionExecutor: DesktopActionExecuting {
    // Serializer + registry are static/internal and tested directly:
    static func serialize(_ root: DesktopUINode, assigningIDsInto registry: inout [String: Int]) -> DesktopSnapshotResult
    // registry maps "e<N>" -> index into the flattened accepted-node list; the live class
    // keeps a parallel [AXUIElement] captured during the same traversal.
}
```

Serialization rules (locked by tests):
- IDs `e1, e2, ...` in depth-first order, only for nodes that pass the filter.
- Filter: skip nodes with no title, no value, and a role in `{"AXGroup", "AXUnknown", "AXSplitGroup", "AXScrollArea"}` UNLESS they have accepted descendants (structural nodes are kept for indentation only when needed - simplest compliant behavior: structural nodes are not listed and their children are promoted one level).
- Line format: `[eN] <role>` + optional ` "<title>"` + optional ` value="<value truncated to 80 chars with …>"` + ` (x,y WxH)` for window-level nodes only + ` focused` if focused + ` disabled` if not enabled. Two-space indent per depth.
- Caps: max 400 accepted elements, max depth 12; when truncated, append final line `… truncated (N elements omitted)`.

- [ ] **Step 1: Failing tests** (pure, no AX): 
- `axSerializerAssignsDepthFirstIDsAndFormatsLines` - hand-built 3-level `DesktopUINode` tree -> exact expected multi-line string.
- `axSerializerPromotesChildrenOfBareStructuralNodes` - AXGroup without title/value disappears, children keep order.
- `axSerializerTruncatesLongValuesAndElementCount` - 80-char value cap with `…`; >400 nodes -> truncation line.
- `axExecutorRejectsActionsWithUnknownElementID` - live class with empty registry: `perform(.press, elementID: "e9")` -> `success:false`, message == `DesktopActionError.staleElementID("e9").toolMessage`.
- `axExecutorReportsMissingAccessibilityPermission` - inject `hasAccessibilityPermission: { false }` (closure init parameter) -> `snapshot` returns `.failure(.accessibilityPermissionMissing)`.

- [ ] **Step 2: Red, then implement.** Live AX parts (not unit-tested, kept thin and obvious):
- `snapshot(appName:)`: resolve app (frontmost via `NSWorkspace.shared.frontmostApplication`, else localized-name match over `runningApplications`), `AXUIElementCreateApplication(pid)`, traverse `kAXChildrenAttribute` building `DesktopUINode` + parallel `[AXUIElement]` for accepted nodes, then `Self.serialize`.
- `perform`: `AXUIElementPerformAction(el, kAXPressAction/kAXRaiseAction)`; `.focus` sets `kAXFocusedAttribute` to true.
- `setText`: `.replace` sets `kAXValueAttribute`; `.insert` sets `kAXSelectedTextAttribute`. NEVER CGEvent keystrokes (IME).
- `screenshot()`: reuse `CompanionScreenCaptureUtility`'s capture path, downscale so the long edge is <= 1568px, PNG-encode.
- Registry invalidation: every `snapshot` call replaces the registry wholesale.

- [ ] **Step 3: build-for-testing green; reviewer runs tests + commits** (`feat: implement AX desktop action executor`).

---

### Task 4: Retire the bundled computer-use plugin

**Files:**
- Modify: `Lorelei/CodexAppServerProtocol.swift` (`desktopActionConfigOverrides` - remove the plugin enablement config; if the overrides become empty, drop the `"config"` key from `threadStartRequest`)
- Modify: `Lorelei/CodexAppServerExecutor.swift` (default `skillInputResolver` becomes `{ [] }`; delete `CodexAppServerSkillInputResolver` and skill-input plumbing if nothing else uses it - check `turnStartRequest(skillInputs:)` consumers)
- Modify: `Lorelei/LoreleiCommandRouter.swift` (`CodexPromptBuilder.desktopActionPrompt` rewritten, see below)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Produces: `desktopActionPrompt` describing the in-house tool workflow. New text (locked by test assertions on the quoted fragments):

```
Use Codex App Server's interactive control plane for every desktop operation.
You control the desktop ONLY through the lorelei.* tools:
1. Call lorelei.foreground_app to bring the target app (or URL) onscreen in the current macOS Space.
2. Call lorelei.desktop_snapshot to read the app's accessibility tree; act on elements by their [eN] ids.
3. Use lorelei.desktop_action (press/focus/raise) and lorelei.set_text (sets values directly - required for non-ASCII text) to operate the UI.
4. After UI state changes, call lorelei.desktop_snapshot again before further actions.
5. Only when the snapshot lacks the information you need (canvas or custom-drawn UIs), call lorelei.screenshot and reason from the image.
Do not simulate keyboard shortcuts. Do not use shell commands to manipulate the UI.
Do not commit changes.
```

  followed by the user request block exactly as today.

- [ ] **Step 1: Update tests first.**
- Rewrite `appServerThreadStartEnablesComputerUsePluginForDesktopActions` -> `appServerThreadStartSendsNoPluginConfig` (no `computer-use@openai-bundled` anywhere in the thread/start line; adapt to whether `config` key is dropped).
- Rewrite `desktopActionPromptRequiresAppServerControlPlaneAndScopedDesktopActions` to assert the new fragments: `"lorelei.desktop_snapshot"`, `"lorelei.desktop_action"`, `"lorelei.set_text"`, `"lorelei.screenshot"`, `"Do not simulate keyboard shortcuts."`, `"Do not commit changes."`, and the embedded user request.
- Delete skill-input tests (`appServerTurnStartCanAttachComputerUseSkillInput` and siblings that exist solely for computer-use SKILL.md inputs).
- `grep -rn 'computer-use' Lorelei LoreleiTests` afterward must be empty (exit 1).

- [ ] **Step 2: Implement, build-for-testing, reviewer runs tests + commits** (`feat: replace bundled computer-use plugin with lorelei tools`).

---

### Task 5: Wire the suite into CompanionManager + phase PR

**Files:**
- Modify: `Lorelei/CompanionManager.swift` (where `CodexAppServerExecutor` is constructed for desktop actions: `dynamicToolSpecsResolver` returns foreground tool spec + `CodexAppServerDesktopToolSuite.toolSpecs()`; `dynamicToolHandler` routes `foreground_app` to the existing handler and the four desktop tools to a lazily-created shared `AXDesktopActionExecutor`)
- Test: `LoreleiTests/LoreleiTests.swift`

**Interfaces:**
- Consumes: everything above. The executor instance is created once per CompanionManager (element registry lifetime spans one turn in practice because every turn starts with a fresh snapshot).

- [ ] **Step 1: Failing test** `companionManagerRegistersDesktopToolSuiteWithForegroundTool` - build the manager with the injected app-server runner fixture, capture the specs passed to `thread/start` (existing fixtures already capture dynamic tool specs for the foreground tool test - follow that pattern), assert all five tool names are present exactly once.

- [ ] **Step 2: Implement wiring; build-for-testing green.**

- [ ] **Step 3: Reviewer: full suite including UI tests, then a LIVE smoke** (requires the three TCC permissions granted): run the app, voice or injected command "open TextEdit and type hello world", confirm foreground -> snapshot -> set_text path in the debug log and on screen. Reviewer commits (`feat: wire desktop tool suite into companion manager`), pushes `phase-3-computer-use-tools`, opens the phase PR referencing the spec and PRD #2, noting the spec #8 revision (dynamic tools instead of MCP shim).
