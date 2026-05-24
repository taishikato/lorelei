# Lorelei Chrome Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Lorelei's blocked `codex exec @chrome` path with a first-party Chrome bridge that can execute a safe Google search from Lorelei and report the observed page state.

**Architecture:** Lorelei will talk to a local Unix domain socket exposed by a Chrome native messaging host. A bundled Chrome extension keeps a native messaging port open, receives bridge commands from the host, performs Chrome tab work in the user's Chrome profile, and returns structured results. The first command set is intentionally small: health check and Google search.

**Tech Stack:** Swift/macOS app, Swift Testing, Node.js native messaging host, Chrome Manifest V3 extension, Unix domain sockets, Chrome native messaging protocol.

---

## File Structure

- `leanring-buddy/ChromeBridgeExecutor.swift`: Swift models, request planner, socket client, and executor for bridge-backed Chrome actions.
- `leanring-buddy/CompanionManager.swift`: Replace `.codexChrome` execution with `ChromeBridgeExecutor`.
- `leanring-buddy/LoreleiCommandRouter.swift`: Update prompt naming only where user-facing semantics still imply Codex Chrome.
- `leanring-buddyTests/leanring_buddyTests.swift`: Unit tests for bridge planning, socket framing, command result summaries, and `.codexChrome` routing.
- `chrome-extension/lorelei-bridge/manifest.json`: Manifest V3 extension with stable key and native messaging permission.
- `chrome-extension/lorelei-bridge/background.js`: Extension service worker that connects to the native host and handles `ping` and `googleSearch`.
- `native-host/lorelei_chrome_native_host.js`: Native messaging host that relays newline JSON socket commands to the extension.
- `native-host/install-dev-host.sh`: Installs the native messaging manifest for development.
- `native-host/e2e-google-smoke.mjs`: Launches Chrome with a temporary profile and extension, sends a Google search command through the socket, and verifies the response.
- `native-host/README.md`: Short development setup and E2E instructions.

---

### Task 1: Swift Bridge Contract and Planner

**Files:**
- Create: `leanring-buddy/ChromeBridgeExecutor.swift`
- Modify: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Write the failing planner tests**

Append these tests to `leanring-buddyTests/leanring_buddyTests.swift`:

```swift
@Test func chromeBridgePlannerBuildsGoogleSearchCommand() async throws {
    let command = ChromeBridgeCommandPlanner.command(for: "search Google for Lorelei voice control smoke test")

    #expect(command == .googleSearch(query: "Lorelei voice control smoke test"))
}

@Test func chromeBridgePlannerRejectsUnsupportedChromeCommands() async throws {
    let command = ChromeBridgeCommandPlanner.command(for: "click the first result")

    #expect(command == nil)
}

@Test func chromeBridgeRequestEncodesSingleJSONLine() async throws {
    let request = ChromeBridgeRequest(
        id: "test-id",
        command: .googleSearch(query: "Lorelei voice control smoke test")
    )

    let line = try ChromeBridgeLineCodec.encode(request)

    #expect(line.hasSuffix("\n"))
    #expect(line.contains("\"type\":\"googleSearch\""))
    #expect(line.contains("\"query\":\"Lorelei voice control smoke test\""))
}

@Test func chromeBridgeResponseSummaryReportsGoogleSearchState() async throws {
    let response = ChromeBridgeResponse(
        id: "test-id",
        ok: true,
        type: "googleSearch",
        title: "Lorelei voice control smoke test - Google Search",
        url: "https://www.google.com/search?q=Lorelei%20voice%20control%20smoke%20test",
        searchValue: "Lorelei voice control smoke test",
        error: nil
    )

    #expect(response.summary == "Chrome Google search opened: Lorelei voice control smoke test")
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Expected: FAIL because `ChromeBridgeCommandPlanner`, `ChromeBridgeRequest`, `ChromeBridgeLineCodec`, and `ChromeBridgeResponse` do not exist.

- [ ] **Step 3: Implement minimal Swift bridge contract**

Create `leanring-buddy/ChromeBridgeExecutor.swift` with:

```swift
//
//  ChromeBridgeExecutor.swift
//  leanring-buddy
//
//  Executes supported Chrome actions through Lorelei's first-party bridge.
//

import Darwin
import Foundation

enum ChromeBridgeCommand: Equatable, Sendable {
    case ping
    case googleSearch(query: String)
}

struct ChromeBridgeRequest: Equatable, Sendable {
    let id: String
    let command: ChromeBridgeCommand
}

struct ChromeBridgeResponse: Codable, Equatable, Sendable {
    let id: String?
    let ok: Bool
    let type: String?
    let title: String?
    let url: String?
    let searchValue: String?
    let error: String?

    var summary: String {
        if ok, type == "googleSearch", let searchValue, !searchValue.isEmpty {
            return "Chrome Google search opened: \(searchValue)"
        }
        if ok {
            return "Chrome bridge command completed."
        }
        return error.map { "Chrome bridge failed: \($0)" } ?? "Chrome bridge failed."
    }
}

struct ChromeBridgeCommandPlanner {
    static func command(for prompt: String) -> ChromeBridgeCommand? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let prefixes = [
            "search google for ",
            "google search for ",
            "search for ",
            "look up "
        ]

        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let query = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : .googleSearch(query: query)
        }

        return nil
    }
}

struct ChromeBridgeLineCodec {
    private struct EncodedRequest: Encodable {
        let id: String
        let type: String
        let query: String?
    }

    static func encode(_ request: ChromeBridgeRequest) throws -> String {
        let encodedRequest: EncodedRequest
        switch request.command {
        case .ping:
            encodedRequest = EncodedRequest(id: request.id, type: "ping", query: nil)
        case .googleSearch(let query):
            encodedRequest = EncodedRequest(id: request.id, type: "googleSearch", query: query)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(encodedRequest)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ChromeBridgeExecutorError.encodingFailed
        }
        return json + "\n"
    }

    static func decodeResponse(_ line: String) throws -> ChromeBridgeResponse {
        let data = Data(line.utf8)
        return try JSONDecoder().decode(ChromeBridgeResponse.self, from: data)
    }
}

enum ChromeBridgeExecutorError: Error, Equatable {
    case encodingFailed
    case unsupportedCommand
    case socketUnavailable(String)
    case responseDecodingFailed
}
```

- [ ] **Step 4: Run tests to verify GREEN**

Run:

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Expected: PASS for the new planner/codec tests.

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/ChromeBridgeExecutor.swift leanring-buddyTests/leanring_buddyTests.swift
git commit -m "feat: add Chrome bridge command contract"
```

---

### Task 2: Swift Socket Executor and Lorelei Integration

**Files:**
- Modify: `leanring-buddy/ChromeBridgeExecutor.swift`
- Modify: `leanring-buddy/CompanionManager.swift`
- Modify: `leanring-buddy/LoreleiCommandRouter.swift`
- Modify: `leanring-buddyTests/leanring_buddyTests.swift`

- [ ] **Step 1: Write the failing executor tests**

Append these tests to `leanring-buddyTests/leanring_buddyTests.swift`:

```swift
@Test func chromeBridgeExecutorReturnsUnsupportedForUnknownPrompt() async throws {
    let executor = ChromeBridgeExecutor(client: StubChromeBridgeClient(responseLine: ""))

    let result = await executor.run(prompt: "click the first result")

    #expect(result.status == .failed)
    #expect(result.summary == "Chrome bridge does not support that browser action yet.")
}

@Test func chromeBridgeExecutorSendsGoogleSearchToClient() async throws {
    let client = StubChromeBridgeClient(
        responseLine: #"{"id":"stub","ok":true,"type":"googleSearch","title":"Lorelei voice control smoke test - Google Search","url":"https://www.google.com/search?q=Lorelei%20voice%20control%20smoke%20test","searchValue":"Lorelei voice control smoke test"}"#
    )
    let executor = ChromeBridgeExecutor(client: client, idGenerator: { "stub" })

    let result = await executor.run(prompt: "search Google for Lorelei voice control smoke test")

    #expect(result.status == .succeeded)
    #expect(result.summary == "Chrome Google search opened: Lorelei voice control smoke test")
    #expect(client.lastSentLine?.contains("\"type\":\"googleSearch\"") == true)
}
```

Add this test helper near the bottom of `leanring-buddyTests/leanring_buddyTests.swift`:

```swift
private final class StubChromeBridgeClient: ChromeBridgeClienting, @unchecked Sendable {
    private let responseLine: String
    private(set) var lastSentLine: String?

    init(responseLine: String) {
        self.responseLine = responseLine
    }

    func send(line: String) async throws -> String {
        lastSentLine = line
        return responseLine
    }
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Expected: FAIL because `ChromeBridgeExecutor` and `ChromeBridgeClienting` do not exist yet.

- [ ] **Step 3: Implement minimal socket executor**

Extend `leanring-buddy/ChromeBridgeExecutor.swift` with:

```swift
protocol ChromeBridgeClienting: Sendable {
    func send(line: String) async throws -> String
}

struct ChromeBridgeExecutor: Sendable {
    private let client: ChromeBridgeClienting
    private let idGenerator: @Sendable () -> String

    init(
        client: ChromeBridgeClienting = ChromeBridgeSocketClient(),
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.client = client
        self.idGenerator = idGenerator
    }

    func run(prompt: String) async -> WorkspaceCommandResult {
        guard let command = ChromeBridgeCommandPlanner.command(for: prompt) else {
            return WorkspaceCommandResult(
                summary: "Chrome bridge does not support that browser action yet.",
                status: .failed
            )
        }

        do {
            let request = ChromeBridgeRequest(id: idGenerator(), command: command)
            let line = try ChromeBridgeLineCodec.encode(request)
            let responseLine = try await client.send(line: line)
            let response = try ChromeBridgeLineCodec.decodeResponse(responseLine)
            return WorkspaceCommandResult(
                summary: response.summary,
                status: response.ok ? .succeeded : .failed
            )
        } catch {
            return WorkspaceCommandResult(
                summary: "Chrome bridge failed: \(error.localizedDescription)",
                status: .failed
            )
        }
    }
}

struct ChromeBridgeSocketClient: ChromeBridgeClienting {
    private let socketPath: String
    private let timeoutSeconds: TimeInterval

    init(
        socketPath: String = ChromeBridgeSocketClient.defaultSocketPath(),
        timeoutSeconds: TimeInterval = 20
    ) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    static func defaultSocketPath() -> String {
        let uid = getuid()
        return "/tmp/lorelei-chrome-bridge-\(uid).sock"
    }

    func send(line: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try Self.sendSynchronously(
                        line: line,
                        socketPath: socketPath,
                        timeoutSeconds: timeoutSeconds
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func sendSynchronously(
        line: String,
        socketPath: String,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw ChromeBridgeExecutorError.socketUnavailable("socket() failed")
        }
        defer { close(fileDescriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            throw ChromeBridgeExecutorError.socketUnavailable("Socket path is too long")
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, maxPathLength)
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ChromeBridgeExecutorError.socketUnavailable("Chrome bridge is not running")
        }

        let lineData = Array(line.utf8)
        let written = Darwin.write(fileDescriptor, lineData, lineData.count)
        guard written == lineData.count else {
            throw ChromeBridgeExecutorError.socketUnavailable("Could not write request")
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            let byteCount = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if byteCount > 0 {
                responseData.append(buffer, count: byteCount)
                if responseData.contains(0x0A) {
                    break
                }
            } else if byteCount == 0 {
                break
            } else {
                throw ChromeBridgeExecutorError.socketUnavailable("Could not read response")
            }
        }

        guard let response = String(data: responseData, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init),
              !response.isEmpty else {
            throw ChromeBridgeExecutorError.responseDecodingFailed
        }
        return response
    }
}
```

- [ ] **Step 4: Wire `.codexChrome` to the bridge**

In `leanring-buddy/CompanionManager.swift`, add:

```swift
private let chromeBridgeExecutor = ChromeBridgeExecutor()
```

Replace the `.codexChrome` confirmed command case with:

```swift
case .codexChrome(let prompt):
    result = await chromeBridgeExecutor.run(prompt: prompt)
    analyticsResponse = "confirmed chrome bridge command"
```

In `leanring-buddy/CompanionManager.swift`, change the `.codexChrome` confirmation title from:

```swift
title: "Run Codex Chrome action?"
```

to:

```swift
title: "Run Chrome action?"
```

- [ ] **Step 5: Run tests to verify GREEN**

Run:

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/ChromeBridgeExecutor.swift leanring-buddy/CompanionManager.swift leanring-buddy/LoreleiCommandRouter.swift leanring-buddyTests/leanring_buddyTests.swift
git commit -m "feat: execute Chrome actions through Lorelei bridge"
```

---

### Task 3: Native Messaging Host

**Files:**
- Create: `native-host/lorelei_chrome_native_host.js`
- Create: `native-host/install-dev-host.sh`
- Create: `native-host/README.md`

- [ ] **Step 1: Write a failing host smoke check**

Run:

```bash
node native-host/lorelei_chrome_native_host.js --check
```

Expected: FAIL with `MODULE_NOT_FOUND` because the host file does not exist.

- [ ] **Step 2: Implement the native host**

Create `native-host/lorelei_chrome_native_host.js`:

```javascript
#!/usr/bin/env node

const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const HOST_NAME = "com.devtaishi.lorelei.chrome_bridge";
const SOCKET_PATH = process.env.LORELEI_CHROME_BRIDGE_SOCKET
  || path.join(os.tmpdir(), `lorelei-chrome-bridge-${process.getuid ? process.getuid() : "user"}.sock`);

if (process.argv.includes("--check")) {
  process.stdout.write(JSON.stringify({ ok: true, hostName: HOST_NAME, socketPath: SOCKET_PATH }) + "\n");
  process.exit(0);
}

const pending = new Map();
let inputBuffer = Buffer.alloc(0);
let extensionReady = false;

function sendNativeMessage(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  process.stdout.write(Buffer.concat([header, body]));
}

function handleNativeMessage(message) {
  if (message && message.type === "ready") {
    extensionReady = true;
    return;
  }
  if (!message || typeof message.id !== "string") {
    return;
  }
  const socket = pending.get(message.id);
  if (!socket) {
    return;
  }
  pending.delete(message.id);
  socket.end(JSON.stringify(message) + "\n");
}

function consumeNativeInput() {
  while (inputBuffer.length >= 4) {
    const size = inputBuffer.readUInt32LE(0);
    if (inputBuffer.length < 4 + size) {
      return;
    }
    const body = inputBuffer.slice(4, 4 + size);
    inputBuffer = inputBuffer.slice(4 + size);
    try {
      handleNativeMessage(JSON.parse(body.toString("utf8")));
    } catch {
      // Ignore malformed extension messages.
    }
  }
}

process.stdin.on("data", (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  consumeNativeInput();
});

process.stdin.on("end", () => process.exit(0));

try {
  fs.unlinkSync(SOCKET_PATH);
} catch {}

const server = net.createServer((socket) => {
  let lineBuffer = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    lineBuffer += chunk;
    const newlineIndex = lineBuffer.indexOf("\n");
    if (newlineIndex === -1) {
      return;
    }
    const line = lineBuffer.slice(0, newlineIndex);
    lineBuffer = lineBuffer.slice(newlineIndex + 1);
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      socket.end(JSON.stringify({ ok: false, error: "Invalid JSON request" }) + "\n");
      return;
    }
    if (!extensionReady) {
      socket.end(JSON.stringify({ id: request.id, ok: false, error: "Chrome extension is not connected" }) + "\n");
      return;
    }
    if (typeof request.id !== "string" || request.id.length === 0) {
      socket.end(JSON.stringify({ ok: false, error: "Request id is required" }) + "\n");
      return;
    }
    pending.set(request.id, socket);
    sendNativeMessage(request);
  });
});

server.listen(SOCKET_PATH, () => {
  fs.chmodSync(SOCKET_PATH, 0o600);
  sendNativeMessage({ type: "hostReady", socketPath: SOCKET_PATH });
});

process.on("SIGTERM", () => {
  try {
    fs.unlinkSync(SOCKET_PATH);
  } catch {}
  process.exit(0);
});
```

- [ ] **Step 3: Add dev host installer**

Create `native-host/install-dev-host.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PATH="$ROOT_DIR/native-host/lorelei_chrome_native_host.js"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/com.devtaishi.lorelei.chrome_bridge.json"
EXTENSION_ID="${1:?Usage: install-dev-host.sh <chrome-extension-id>}"

chmod +x "$HOST_PATH"
mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST_PATH" <<JSON
{
  "name": "com.devtaishi.lorelei.chrome_bridge",
  "description": "Lorelei Chrome bridge",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXTENSION_ID/"
  ]
}
JSON

echo "$MANIFEST_PATH"
```

- [ ] **Step 4: Add native host README**

Create `native-host/README.md`:

```markdown
# Lorelei Chrome Native Host

The host is launched by the Lorelei Chrome extension through Chrome native messaging.
It exposes a Unix domain socket at `/tmp/lorelei-chrome-bridge-$(id -u).sock`.

Development setup:

```bash
native-host/install-dev-host.sh <extension-id>
```

Health check:

```bash
node native-host/lorelei_chrome_native_host.js --check
```
```

- [ ] **Step 5: Run host smoke check**

Run:

```bash
node native-host/lorelei_chrome_native_host.js --check
```

Expected: PASS with JSON containing `"ok":true`.

- [ ] **Step 6: Commit**

```bash
git add native-host/lorelei_chrome_native_host.js native-host/install-dev-host.sh native-host/README.md
git commit -m "feat: add Lorelei Chrome native host"
```

---

### Task 4: Chrome Extension

**Files:**
- Create: `chrome-extension/lorelei-bridge/manifest.json`
- Create: `chrome-extension/lorelei-bridge/background.js`

- [ ] **Step 1: Write a failing manifest validation**

Run:

```bash
node -e 'const fs=require("fs"); const m=JSON.parse(fs.readFileSync("chrome-extension/lorelei-bridge/manifest.json","utf8")); if (m.name !== "Lorelei Chrome Bridge") process.exit(1)'
```

Expected: FAIL because the manifest does not exist.

- [ ] **Step 2: Create manifest**

Create `chrome-extension/lorelei-bridge/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "Lorelei Chrome Bridge",
  "version": "0.1.0",
  "description": "Lets Lorelei execute supported browser actions in Chrome.",
  "key": "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvRWSWtDZDMkavvPk8qexexcrGWCXBopbYebKYElPVFz2+2jDfGOVl7Qh67pQDLK+dQNEX9U06s3JABuUQQw+2u6jqZwvX3M7ICNC2zHNaMhh2vOHHTS+Fqhcop4Z/t3E3vHnq7X7VBwZHSscU/160jx88LG5TUW5YtmvDR7Nx4Jr+1tuuFyxqUOmYaUsFh/iV77MNYDoZ88ExJVoSbRmLhWHCIAUbhPWeHoCUmxP61pprydNghHjGeTXQH1uAAGbOf0gBlDYMJF+k/uDdTxBS92Or1/TadW2N0T5cgzR6/4hroqnQRMafDITMPFcXCAVS+WU3vC2fAs1z0fw6vkVFQIDAQAB",
  "permissions": [
    "nativeMessaging",
    "scripting",
    "tabs"
  ],
  "host_permissions": [
    "https://www.google.com/*"
  ],
  "background": {
    "service_worker": "background.js"
  }
}
```

- [ ] **Step 3: Create background service worker**

Create `chrome-extension/lorelei-bridge/background.js`:

```javascript
const HOST_NAME = "com.devtaishi.lorelei.chrome_bridge";
let nativePort = null;

function connectNativeHost() {
  try {
    nativePort = chrome.runtime.connectNative(HOST_NAME);
    nativePort.onMessage.addListener((message) => {
      if (message && message.type === "hostReady") {
        nativePort.postMessage({ type: "ready" });
        return;
      }
      handleCommand(message);
    });
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      setTimeout(connectNativeHost, 1000);
    });
    nativePort.postMessage({ type: "ready" });
  } catch {
    nativePort = null;
    setTimeout(connectNativeHost, 1000);
  }
}

function postResponse(response) {
  if (nativePort) {
    nativePort.postMessage(response);
  }
}

async function handleCommand(message) {
  if (!message || typeof message.id !== "string") {
    return;
  }
  try {
    if (message.type === "ping") {
      postResponse({ id: message.id, ok: true, type: "ping" });
      return;
    }
    if (message.type === "googleSearch") {
      const result = await googleSearch(message.query || "");
      postResponse({ id: message.id, ok: true, type: "googleSearch", ...result });
      return;
    }
    postResponse({ id: message.id, ok: false, type: message.type, error: "Unsupported command" });
  } catch (error) {
    postResponse({
      id: message.id,
      ok: false,
      type: message.type,
      error: error instanceof Error ? error.message : String(error)
    });
  }
}

async function googleSearch(query) {
  const trimmedQuery = String(query).trim();
  if (!trimmedQuery) {
    throw new Error("Google search query is required");
  }
  const url = `https://www.google.com/search?q=${encodeURIComponent(trimmedQuery)}`;
  const tab = await chrome.tabs.create({ active: true, url });
  await waitForTabComplete(tab.id, 15000);
  const [injection] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: () => {
      const input = document.querySelector("textarea[name='q'], input[name='q']");
      return {
        title: document.title,
        url: location.href,
        searchValue: input ? input.value : ""
      };
    }
  });
  return injection.result;
}

function waitForTabComplete(tabId, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      reject(new Error("Timed out waiting for Google search page"));
    }, timeoutMs);
    const listener = (updatedTabId, changeInfo) => {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        clearTimeout(timeout);
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      }
    };
    chrome.tabs.onUpdated.addListener(listener);
  });
}

connectNativeHost();
```

- [ ] **Step 4: Run manifest validation**

Run:

```bash
node -e 'const fs=require("fs"); const m=JSON.parse(fs.readFileSync("chrome-extension/lorelei-bridge/manifest.json","utf8")); if (m.name !== "Lorelei Chrome Bridge") process.exit(1); if (!m.permissions.includes("nativeMessaging")) process.exit(1)'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add chrome-extension/lorelei-bridge/manifest.json chrome-extension/lorelei-bridge/background.js
git commit -m "feat: add Lorelei Chrome extension"
```

---

### Task 5: Google E2E Smoke Test

**Files:**
- Create: `native-host/e2e-google-smoke.mjs`
- Modify: `native-host/README.md`

- [ ] **Step 1: Write a failing E2E script check**

Run:

```bash
node native-host/e2e-google-smoke.mjs --help
```

Expected: FAIL because the script does not exist.

- [ ] **Step 2: Create E2E script**

Create `native-host/e2e-google-smoke.mjs`:

```javascript
#!/usr/bin/env node

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const extensionPath = path.join(root, "chrome-extension", "lorelei-bridge");
const hostInstallerPath = path.join(root, "native-host", "install-dev-host.sh");
const extensionId = "eaiefhpgoknofichehnpopdjbhlolech";
const socketPath = process.env.LORELEI_CHROME_BRIDGE_SOCKET
  || path.join(os.tmpdir(), `lorelei-chrome-bridge-${process.getuid()}.sock`);
const query = "Lorelei voice control smoke test";

if (process.argv.includes("--help")) {
  console.log("Runs a Google-only Chrome bridge smoke test.");
  process.exit(0);
}

function chromePath() {
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
  ];
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) {
    throw new Error("Google Chrome is not installed");
  }
  return found;
}

function sendSocketCommand(command) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let data = "";
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("Timed out waiting for bridge response"));
    }, 25000);
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(JSON.stringify(command) + "\n"));
    socket.on("data", (chunk) => {
      data += chunk;
      if (data.includes("\n")) {
        clearTimeout(timeout);
        socket.end();
        resolve(JSON.parse(data.split("\n")[0]));
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

async function waitForSocket() {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (fs.existsSync(socketPath)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Bridge socket did not appear: ${socketPath}`);
}

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), "lorelei-chrome-e2e-"));
await new Promise((resolve, reject) => {
  const installer = spawn(hostInstallerPath, [extensionId], { stdio: "ignore" });
  installer.on("exit", (code) => code === 0 ? resolve() : reject(new Error(`Native host installer exited ${code}`)));
  installer.on("error", reject);
});

try {
  fs.unlinkSync(socketPath);
} catch {}

const chrome = spawn(chromePath(), [
  `--user-data-dir=${userDataDir}`,
  `--load-extension=${extensionPath}`,
  "--no-first-run",
  "--no-default-browser-check",
  "about:blank"
], { stdio: "ignore" });

try {
  await waitForSocket();
  const response = await sendSocketCommand({
    id: "e2e-google",
    type: "googleSearch",
    query
  });
  if (!response.ok) {
    throw new Error(response.error || "Bridge command failed");
  }
  if (response.searchValue !== query && !String(response.title || "").includes(query)) {
    throw new Error(`Google result did not contain query: ${JSON.stringify(response)}`);
  }
  console.log(JSON.stringify({
    ok: true,
    title: response.title,
    url: response.url,
    searchValue: response.searchValue
  }, null, 2));
} finally {
  chrome.kill("SIGTERM");
}
```

- [ ] **Step 3: Update README E2E section**

Append to `native-host/README.md`:

```markdown
Google-only E2E smoke test:

```bash
node native-host/e2e-google-smoke.mjs
```

The script launches Chrome with a temporary profile and the local unpacked extension, sends a single Google search command, and verifies the returned title or search box value.
```

- [ ] **Step 4: Run E2E**

Run:

```bash
node native-host/e2e-google-smoke.mjs
```

Expected: PASS with JSON containing `"ok": true` and `"searchValue": "Lorelei voice control smoke test"` or a title containing the same query.

- [ ] **Step 5: Commit**

```bash
git add native-host/e2e-google-smoke.mjs native-host/README.md
git commit -m "test: add Chrome bridge Google smoke test"
```

---

## Final Verification

- [ ] Run full tests:

```bash
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

- [ ] Run host check:

```bash
node native-host/lorelei_chrome_native_host.js --check
```

- [ ] Run Google-only E2E:

```bash
node native-host/e2e-google-smoke.mjs
```

- [ ] Confirm no stray processes:

```bash
ps -A -o pid=,ppid=,stat=,command= | grep -E 'lorelei_chrome_native_host|Google Chrome.*lorelei-chrome-e2e' | grep -v grep
```

- [ ] Confirm git status:

```bash
git status --short --branch
```
