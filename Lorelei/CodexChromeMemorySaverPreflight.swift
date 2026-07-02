//
//  CodexChromeMemorySaverPreflight.swift
//  Lorelei
//
//  Best-effort Chrome tab wakeup before App Server Chrome automation.
//

import Foundation

typealias ChromeMemorySaverScriptRunner = @Sendable (
    _ script: String,
    _ timeoutSeconds: TimeInterval
) async -> WorkspaceProcessExecution

struct CodexChromeMemorySaverPreflight {
    private let scriptRunner: ChromeMemorySaverScriptRunner
    private let timeoutSeconds: TimeInterval

    init(
        timeoutSeconds: TimeInterval = 8,
        scriptRunner: ChromeMemorySaverScriptRunner? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.scriptRunner = scriptRunner ?? Self.liveScriptRunner
    }

    func run(prompt: String) async -> CodexAppServerPreflightResult {
        let runDecision = shouldRun(for: prompt)
        guard runDecision.shouldRun else {
            if runDecision.isExplicitNonChromeBrowser {
                return .completed("Chrome preflight skipped: prompt targets a non-Chrome browser.")
            }
            return .completed("Chrome preflight skipped: prompt does not mention Chrome or a browser.")
        }

        let execution = await scriptRunner(Self.nodeScript, timeoutSeconds)
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .exited(0) = execution.reason else {
            let detail = stderr.isEmpty ? (stdout.isEmpty ? reasonDescription(execution.reason) : stdout) : stderr
            return .warning("Chrome preflight could not complete: \(detail)")
        }

        guard let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let pageTargets = root["pageTargets"] as? Int,
              let woken = root["woken"] as? Int else {
            return .warning("Chrome preflight could not parse script output.")
        }

        return .completed("Chrome preflight checked \(pageTargets) tabs and woke \(woken) sleeping tabs.")
    }

    private func shouldRun(for prompt: String) -> (shouldRun: Bool, isExplicitNonChromeBrowser: Bool) {
        let lowercasedPrompt = prompt.lowercased()
        if lowercasedPrompt.contains("chrome")
            || lowercasedPrompt.contains("chatgpt") {
            return (true, false)
        }
        if Self.nonChromeBrowserNames.contains(where: { containsWord($0, in: lowercasedPrompt) }) {
            return (false, true)
        }
        return (lowercasedPrompt.contains("browser"), false)
    }

    private func containsWord(_ word: String, in text: String) -> Bool {
        text.range(
            of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
            options: .regularExpression
        ) != nil
    }

    private static let nonChromeBrowserNames = [
        "safari",
        "firefox",
        "arc",
        "edge",
        "brave",
        "opera"
    ]

    private func reasonDescription(_ reason: WorkspaceProcessExecution.Reason) -> String {
        switch reason {
        case .exited(let status):
            return "script exited with status \(status)"
        case .timedOut:
            return "script timed out"
        case .cancelled:
            return "script was cancelled"
        case .failedToStart(let error):
            return error.localizedDescription
        }
    }

    private static func liveScriptRunner(
        script: String,
        timeoutSeconds: TimeInterval
    ) async -> WorkspaceProcessExecution {
        let fileManager = FileManager.default
        let scriptURL = fileManager.temporaryDirectory
            .appendingPathComponent("lorelei-chrome-memory-saver-\(UUID().uuidString)")
            .appendingPathExtension("mjs")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return WorkspaceProcessExecution(
                reason: .failedToStart(error),
                stdout: "",
                stderr: error.localizedDescription
            )
        }
        defer {
            try? fileManager.removeItem(at: scriptURL)
        }

        return await WorkspaceProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", scriptURL.path],
            currentDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            timeoutSeconds: timeoutSeconds,
            prelaunchDelay: 0
        )
    }

    private static let nodeScript = #"""
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class CDPWebSocket {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.messages = [];
    this.waiters = [];
    this.nextID = 1;

    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.drainFrames();
    });
    socket.on('error', (error) => this.rejectWaiters(error));
    socket.on('close', () => this.rejectWaiters(new Error('CDP websocket closed')));
  }

  static connect(urlString) {
    const url = new URL(urlString);
    const port = Number(url.port || 80);
    const host = url.hostname;
    const key = crypto.randomBytes(16).toString('base64');

    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host, port });
      let handshake = Buffer.alloc(0);

      const fail = (error) => {
        socket.destroy();
        reject(error);
      };

      socket.setTimeout(1500, () => fail(new Error('CDP websocket handshake timed out')));
      socket.once('error', fail);
      socket.on('connect', () => {
        socket.write(
          `GET ${url.pathname}${url.search} HTTP/1.1\r\n` +
          `Host: ${host}:${port}\r\n` +
          'Upgrade: websocket\r\n' +
          'Connection: Upgrade\r\n' +
          `Sec-WebSocket-Key: ${key}\r\n` +
          'Sec-WebSocket-Version: 13\r\n\r\n'
        );
      });
      socket.on('data', function onHandshake(chunk) {
        handshake = Buffer.concat([handshake, chunk]);
        const boundary = handshake.indexOf('\r\n\r\n');
        if (boundary === -1) return;

        const header = handshake.subarray(0, boundary).toString('utf8');
        if (!header.includes(' 101 ')) {
          fail(new Error('CDP websocket upgrade failed'));
          return;
        }

        socket.off('data', onHandshake);
        socket.off('error', fail);
        socket.setTimeout(0);
        const client = new CDPWebSocket(socket);
        const rest = handshake.subarray(boundary + 4);
        if (rest.length > 0) {
          client.buffer = rest;
          client.drainFrames();
        }
        resolve(client);
      });
    });
  }

  send(method, params = {}) {
    const id = this.nextID++;
    const payload = JSON.stringify({ id, method, params });
    this.socket.write(this.encodeFrame(payload));
    return this.waitFor((message) => message.id === id, 1000)
      .then((message) => {
        if (message.error) {
          throw new Error(message.error.message || `${method} failed`);
        }
        return message.result;
      });
  }

  waitFor(predicate, timeoutMs) {
    const existingIndex = this.messages.findIndex(predicate);
    if (existingIndex !== -1) {
      const [message] = this.messages.splice(existingIndex, 1);
      return Promise.resolve(message);
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter !== waiterRecord);
        reject(new Error('CDP command timed out'));
      }, timeoutMs);
      const waiterRecord = { predicate, resolve, reject, timer };
      this.waiters.push(waiterRecord);
    });
  }

  rejectWaiters(error) {
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }

  deliver(message) {
    const waiterIndex = this.waiters.findIndex((waiter) => waiter.predicate(message));
    if (waiterIndex === -1) {
      this.messages.push(message);
      return;
    }

    const [waiter] = this.waiters.splice(waiterIndex, 1);
    clearTimeout(waiter.timer);
    waiter.resolve(message);
  }

  drainFrames() {
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      let offset = 2;
      let length = second & 0x7f;

      if (length === 126) {
        if (this.buffer.length < offset + 2) return;
        length = this.buffer.readUInt16BE(offset);
        offset += 2;
      } else if (length === 127) {
        if (this.buffer.length < offset + 8) return;
        length = Number(this.buffer.readBigUInt64BE(offset));
        offset += 8;
      }

      const masked = (second & 0x80) !== 0;
      const maskLength = masked ? 4 : 0;
      if (this.buffer.length < offset + maskLength + length) return;

      let payload = this.buffer.subarray(offset + maskLength, offset + maskLength + length);
      if (masked) {
        const mask = this.buffer.subarray(offset, offset + 4);
        payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
      }
      this.buffer = this.buffer.subarray(offset + maskLength + length);

      if (opcode === 0x8) {
        this.socket.end();
        return;
      }
      if (opcode !== 0x1) continue;

      try {
        this.deliver(JSON.parse(payload.toString('utf8')));
      } catch {
        // Ignore malformed event frames; command responses still drive the probe.
      }
    }
  }

  encodeFrame(payload) {
    const body = Buffer.from(payload, 'utf8');
    const mask = crypto.randomBytes(4);
    let header;

    if (body.length < 126) {
      header = Buffer.from([0x81, 0x80 | body.length]);
    } else if (body.length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(body.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(body.length), 2);
    }

    const maskedBody = Buffer.from(body.map((byte, index) => byte ^ mask[index % 4]));
    return Buffer.concat([header, mask, maskedBody]);
  }

  close() {
    this.socket.end();
  }
}

function withTimeout(promise, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('probe timed out')), timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

const activePortPath = path.join(
  os.homedir(),
  'Library/Application Support/Google/Chrome/DevToolsActivePort'
);
const activePort = await fs.readFile(activePortPath, 'utf8');
const [portLine, browserPathLine] = activePort.trim().split(/\r?\n/);
if (!portLine || !browserPathLine) {
  throw new Error('DevToolsActivePort is incomplete');
}

const browserURL = `ws://127.0.0.1:${portLine}${browserPathLine}`;
const cdp = await CDPWebSocket.connect(browserURL);

try {
  const targetResult = await cdp.send('Target.getTargets');
  const pageTargets = (targetResult.targetInfos || []).filter((target) => {
    const url = target.url || '';
    return target.type === 'page'
      && !url.startsWith('chrome://')
      && !url.startsWith('devtools://');
  });

  let woken = 0;
  for (const target of pageTargets) {
    try {
      const attachResult = await withTimeout(
        cdp.send('Target.attachToTarget', { targetId: target.targetId, flatten: true }),
        400
      );
      if (attachResult.sessionId) {
        await cdp.send('Target.detachFromTarget', { sessionId: attachResult.sessionId }).catch(() => {});
      }
    } catch {
      await cdp.send('Target.activateTarget', { targetId: target.targetId });
      await sleep(250);
      woken += 1;
    }
  }

  console.log(JSON.stringify({ ok: true, pageTargets: pageTargets.length, woken }));
} finally {
  cdp.close();
}
"""#
}
