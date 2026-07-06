# Plan 003: Stop the JSON decoder from turning integer 0/1 into booleans

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 120103a..HEAD -- Lorelei/CodexAppServerProtocol.swift LoreleiTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (CI from plan 001 strengthens verification if merged)
- **Category**: bug
- **Planned at**: commit `120103a`, 2026-07-06

## Why this matters

`CodexAppServerJSONValue` decodes JSON coming from the `codex app-server`
subprocess (dynamic tool arguments, permission payloads) and re-emits it when
Lorelei responds. `JSONSerialization` represents both JSON numbers and JSON
booleans as `NSNumber`, and in Swift `NSNumber as? Bool` SUCCEEDS for the
integer values 0 and 1. Because the decoder checks `Bool` before `NSNumber`, a
JSON integer `0` or `1` is decoded as `false`/`true` and re-emitted as a JSON
boolean - silently corrupting round-tripped values. Today the desktop tools
only read string fields, so the bug is latent; it fires the moment any numeric
tool argument or permission scalar with value 0/1 is introduced. This is a
classic Foundation bridging pitfall with a small, well-known fix.

## Current state

- `Lorelei/CodexAppServerProtocol.swift` - the JSON-RPC protocol layer for the
  codex app-server subprocess. The buggy initializer (lines 88-96 at the
  planned-at commit):

```swift
init?(_ value: Any) {
    switch value {
    case _ as NSNull:
        self = .null
    case let value as Bool:          // <-- matches NSNumber(0)/NSNumber(1) too
        self = .bool(value)
    case let value as NSNumber:
        self = .number(value.doubleValue)
    case let value as String:
        self = .string(value)
    ...
```

- The enum's cases (lines 80-86): `.string(String)`, `.object([String: ...])`,
  `.array([...])`, `.number(Double)`, `.bool(Bool)`, `.null`. Re-emission
  happens in `var jsonObject: Any` (line 122+), which turns `.bool` back into
  a Swift `Bool` - so a misclassified 1 becomes JSON `true` on the wire.
- Values reach this initializer from `JSONSerialization.jsonObject(with:)`
  output (inbound lines from the subprocess).
- Repo conventions: comments only for non-obvious constraints; plain dash `-`;
  tests are Swift Testing (`@Test`, `#expect`) - small per-subject test files
  exist (e.g. `LoreleiTests/LoreleiAnalyticsTests.swift`, 48 lines - use it as
  the structural pattern for a new file).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Debug -derivedDataPath DerivedData test -test-timeouts-enabled YES -default-test-execution-time-allowance 60` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `Lorelei/CodexAppServerProtocol.swift` - only the `CodexAppServerJSONValue.init?(_:)` body
- `LoreleiTests/CodexAppServerJSONValueTests.swift` (create)

**Out of scope** (do NOT touch):
- `jsonObject` emission code, `parseInboundLine`, or any other function in the
  protocol file.
- Existing tests in `LoreleiTests/LoreleiTests.swift`.

## Git workflow

- Branch: `json-bool-number-fix`
- Commit style: `fix: keep JSON integers 0/1 numeric in CodexAppServerJSONValue`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reorder the type test using CFBoolean identity

Replace the `case let value as Bool:` arm so that only true JSON booleans
(`__NSCFBoolean` / `CFBoolean`) match it, and 0/1 integers fall through to the
number arm. Target shape:

```swift
init?(_ value: Any) {
    switch value {
    case _ as NSNull:
        self = .null
    // JSONSerialization surfaces both numbers and booleans as NSNumber, and
    // `NSNumber as? Bool` also succeeds for integer 0/1 - identify real JSON
    // booleans by CFBoolean type identity so 0/1 stay numeric.
    case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
        self = .bool(value.boolValue)
    case let value as NSNumber:
        self = .number(value.doubleValue)
    case let value as String:
        ...(rest unchanged)
```

You may need `import CoreFoundation` - check the file's imports first
(`Foundation` re-exports what's needed on macOS; add an import only if the
build demands it).

**Verify**: build command → `** BUILD SUCCEEDED **`.

### Step 2: Add regression tests in a new file

Create `LoreleiTests/CodexAppServerJSONValueTests.swift`, modeled structurally
on `LoreleiTests/LoreleiAnalyticsTests.swift` (header comment, `import Testing`,
`@testable import Lorelei`, one `struct` of `@Test` funcs). Decode via
`JSONSerialization` from literal JSON data so the test exercises the real
bridging, e.g.:

```swift
let object = try JSONSerialization.jsonObject(with: Data(#"{"n0":0,"n1":1,"t":true,"f":false,"pi":3.5}"#.utf8))
let value = try #require(CodexAppServerJSONValue(object))
```

Cases to cover (each a `#expect`):
1. `0` and `1` decode as `.number(0)` / `.number(1)`, not `.bool`.
2. `true` / `false` decode as `.bool(true)` / `.bool(false)`.
3. `3.5` decodes as `.number(3.5)`.
4. Round-trip: `value.jsonObject` re-serialized via
   `JSONSerialization.data(withJSONObject:)` and decoded again keeps `n1`
   comparable to the number 1 and `t` as a boolean (assert via
   `CFGetTypeID` on the round-tripped members, mirroring step 1's check).
5. Nested: the same holds for `0`/`true` inside an array inside an object.

If pattern-matching `.number`/`.bool` requires it, make the enum's cases
comparable in tests via `if case let` - do not add Equatable conformance to
production code unless it already exists (check first: `grep -n "enum CodexAppServerJSONValue" -A2 Lorelei/CodexAppServerProtocol.swift`).

**Verify**: test command → `** TEST SUCCEEDED **`, and the new tests appear in
the log (`grep "CodexAppServerJSONValueTests" <log>`).

### Step 3: Full suite

Run the full test command once more from a clean state to ensure no other
protocol test regressed (several existing tests exercise `parseInboundLine`
with scripted JSON lines).

**Verify**: `** TEST SUCCEEDED **`.

## Test plan

Covered by step 2 (5 new `@Test` cases in
`LoreleiTests/CodexAppServerJSONValueTests.swift`). Pattern:
`LoreleiTests/LoreleiAnalyticsTests.swift`.

## Done criteria

- [ ] Build and full test suite pass (commands above)
- [ ] New test file exists with the 5 cases; all pass
- [ ] `git diff --stat` touches only the two in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- The initializer at `CodexAppServerProtocol.swift:88` does not match the
  excerpt (drift) - reconcile before editing.
- After the fix, any EXISTING test fails: some scripted payload may have been
  (wrongly) relying on 0/1-as-bool. Report the failing test - do not adjust
  its expectations yourself; the correct wire value is a product question.
- `CFGetTypeID` is unavailable or the where-clause pattern does not compile
  after one honest attempt - report with the compiler error.

## Maintenance notes

- Anyone adding numeric tool arguments to the desktop tool suite
  (`CodexAppServerDesktopToolSuite.swift`) now gets correct numbers; before
  this fix they would have received booleans for 0/1.
- Reviewer should scrutinize: that `.bool` still round-trips as JSON
  true/false (case 4), since `jsonObject` returns a Swift `Bool` which
  serializes correctly.
