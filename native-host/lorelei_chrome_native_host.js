#!/usr/bin/env node

const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const HOST_NAME = "com.devtaishi.lorelei.chrome_bridge";
const MAX_NATIVE_MESSAGE_BYTES = 1024 * 1024;
const MAX_SOCKET_REQUEST_BYTES = 1024 * 1024;
const SOCKET_PATH =
  process.env.LORELEI_CHROME_BRIDGE_SOCKET ||
  path.join(
    os.tmpdir(),
    `lorelei-chrome-bridge-${process.getuid ? process.getuid() : "user"}.sock`
  );

if (process.argv.includes("--check")) {
  process.stdout.write(
    `${JSON.stringify({ ok: true, hostName: HOST_NAME, socketPath: SOCKET_PATH })}\n`
  );
  process.exit(0);
}

let extensionReady = false;
let inputBuffer = Buffer.alloc(0);
const pending = new Map();

function sendNativeMessage(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  process.stdout.write(Buffer.concat([header, body]));
}

function writeSocketLine(socket, message) {
  socket.end(`${JSON.stringify(message)}\n`);
}

function cleanupSocketPath() {
  try {
    if (fs.existsSync(SOCKET_PATH)) {
      fs.unlinkSync(SOCKET_PATH);
    }
  } catch (error) {
    process.stderr.write(`Failed to remove socket path: ${error.message}\n`);
  }
}

function handleNativeMessage(message) {
  if (message && message.type === "ready") {
    extensionReady = true;
  }

  if (!message || typeof message.id !== "string") {
    return;
  }

  const socket = pending.get(message.id);
  if (!socket) {
    return;
  }

  pending.delete(message.id);
  writeSocketLine(socket, message);
}

function consumeNativeInput() {
  while (inputBuffer.length >= 4) {
    const bodyLength = inputBuffer.readUInt32LE(0);
    if (bodyLength > MAX_NATIVE_MESSAGE_BYTES) {
      process.stderr.write(
        `Native message is too large: ${bodyLength} bytes exceeds ${MAX_NATIVE_MESSAGE_BYTES}\n`
      );
      process.exit(1);
    }

    if (inputBuffer.length < 4 + bodyLength) {
      return;
    }

    const body = inputBuffer.subarray(4, 4 + bodyLength);
    inputBuffer = inputBuffer.subarray(4 + bodyLength);

    try {
      handleNativeMessage(JSON.parse(body.toString("utf8")));
    } catch (error) {
      process.stderr.write(`Invalid native message: ${error.message}\n`);
    }
  }
}

function handleSocket(socket) {
  let buffer = "";

  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    const newlineIndex = buffer.indexOf("\n");
    if (newlineIndex === -1) {
      if (Buffer.byteLength(buffer, "utf8") > MAX_SOCKET_REQUEST_BYTES) {
        writeSocketLine(socket, { ok: false, error: "Socket request is too large" });
      }
      return;
    }

    const line = buffer.slice(0, newlineIndex);
    if (Buffer.byteLength(line, "utf8") > MAX_SOCKET_REQUEST_BYTES) {
      writeSocketLine(socket, { ok: false, error: "Socket request is too large" });
      return;
    }

    let request;
    try {
      request = JSON.parse(line);
    } catch (_error) {
      writeSocketLine(socket, { ok: false, error: "Invalid JSON request" });
      return;
    }

    if (!extensionReady) {
      writeSocketLine(socket, {
        id: request && request.id,
        ok: false,
        error: "Chrome extension is not connected",
      });
      return;
    }

    if (!request || typeof request.id !== "string") {
      writeSocketLine(socket, { ok: false, error: "Request id is required" });
      return;
    }

    if (pending.has(request.id)) {
      writeSocketLine(socket, {
        id: request.id,
        ok: false,
        error: "Duplicate request id",
      });
      return;
    }

    pending.set(request.id, socket);
    sendNativeMessage(request);
  });

  socket.on("close", () => {
    for (const [id, pendingSocket] of pending.entries()) {
      if (pendingSocket === socket) {
        pending.delete(id);
      }
    }
  });
}

cleanupSocketPath();

const server = net.createServer(handleSocket);

server.on("error", (error) => {
  process.stderr.write(`Native host socket error: ${error.message}\n`);
  process.exitCode = 1;
});

server.listen(SOCKET_PATH, () => {
  fs.chmodSync(SOCKET_PATH, 0o600);
  sendNativeMessage({ type: "hostReady", socketPath: SOCKET_PATH });
});

process.stdin.on("data", (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  consumeNativeInput();
});

process.on("SIGTERM", () => {
  server.close(() => {
    cleanupSocketPath();
    process.exit(0);
  });
});
