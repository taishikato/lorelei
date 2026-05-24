#!/usr/bin/env node

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

const extensionPath = path.join(repoRoot, "chrome-extension", "lorelei-bridge");
const hostInstallerPath = path.join(repoRoot, "native-host", "install-dev-host.sh");
const extensionId = "eaiefhpgoknofichehnpopdjbhlolech";
const socketPath =
  process.env.LORELEI_CHROME_BRIDGE_SOCKET ||
  path.join(
    os.tmpdir(),
    `lorelei-chrome-bridge-${process.getuid ? process.getuid() : "user"}.sock`
  );
const query = "Lorelei voice control smoke test";

const HELP = `Usage: node native-host/e2e-google-smoke.mjs

Launches Google Chrome with the local Lorelei bridge extension, sends a
googleSearch command through the native host Unix socket, and verifies Google
received the smoke-test query.
`;

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  process.stdout.write(HELP);
  process.exit(0);
}

function chromePath() {
  const candidates = [
    ...chromeForTestingPaths(),
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error("Google Chrome or Google Chrome Canary was not found in /Applications");
}

function chromeForTestingPaths() {
  const baseDirs = [
    path.join(os.tmpdir(), "lorelei-browsers", "chrome"),
    "/tmp/lorelei-browsers/chrome",
  ];
  const paths = [];

  for (const baseDir of baseDirs) {
    try {
      paths.push(
        ...fs
          .readdirSync(baseDir)
          .filter((entry) => entry.startsWith("mac_"))
          .map((entry) =>
            path.join(
              baseDir,
              entry,
              "chrome-mac-arm64",
              "Google Chrome for Testing.app",
              "Contents",
              "MacOS",
              "Google Chrome for Testing"
            )
          )
      );
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
    }
  }

  return paths;
}

function runInstaller() {
  const result = spawn(hostInstallerPath, [extensionId], {
    cwd: repoRoot,
    stdio: ["ignore", "pipe", "pipe"],
  });

  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";

    result.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    result.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    result.on("error", reject);
    result.on("close", (code) => {
      if (code === 0) {
        resolve(stdout.trim());
        return;
      }

      reject(new Error(`install-dev-host.sh exited ${code}: ${stderr || stdout}`));
    });
  });
}

async function installProfileManifest(userDataDir, manifestPath) {
  if (!manifestPath) {
    return null;
  }

  const hostLogPath = path.join(userDataDir, "lorelei-native-host.log");
  const hostWrapperPath = path.join(userDataDir, "lorelei-native-host-wrapper.sh");
  const manifest = JSON.parse(await fs.promises.readFile(manifestPath, "utf8"));
  await fs.promises.writeFile(
    hostWrapperPath,
    `#!/usr/bin/env bash
exec "${manifest.path}" 2>>"${hostLogPath}"
`
  );
  await fs.promises.chmod(hostWrapperPath, 0o700);
  manifest.path = hostWrapperPath;

  const profileManifestDir = path.join(userDataDir, "NativeMessagingHosts");
  await fs.promises.mkdir(profileManifestDir, { recursive: true });
  await fs.promises.writeFile(
    path.join(profileManifestDir, "com.devtaishi.lorelei.chrome_bridge.json"),
    `${JSON.stringify(manifest, null, 2)}\n`
  );

  return hostLogPath;
}

async function unlinkStaleSocket() {
  try {
    await fs.promises.unlink(socketPath);
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw error;
    }
  }
}

async function waitForSocket(timeoutMs = 20_000) {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    try {
      const stats = await fs.promises.stat(socketPath);
      if (stats.isSocket()) {
        return;
      }
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  throw new Error(`Timed out waiting for socket: ${socketPath}`);
}

function sendSocketCommand(command, timeoutMs = 25_000) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let buffer = "";
    let settled = false;
    const timeout = setTimeout(() => {
      finish(new Error(`Timed out waiting for socket response: ${socketPath}`));
      socket.destroy();
    }, timeoutMs);

    function finish(error, value) {
      if (settled) {
        return;
      }

      settled = true;
      clearTimeout(timeout);
      if (error) {
        reject(error);
        return;
      }

      resolve(value);
    }

    socket.on("connect", () => {
      socket.write(`${JSON.stringify(command)}\n`);
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newlineIndex = buffer.indexOf("\n");
      if (newlineIndex === -1) {
        return;
      }

      const line = buffer.slice(0, newlineIndex);
      try {
        finish(null, JSON.parse(line));
      } catch (error) {
        finish(error);
      } finally {
        socket.end();
      }
    });

    socket.on("error", finish);
    socket.on("end", () => {
      if (!settled) {
        finish(new Error("Socket closed before a newline response was received"));
      }
    });
  });
}

function launchChrome(userDataDir) {
  return spawn(
    chromePath(),
    [
      `--user-data-dir=${userDataDir}`,
      `--load-extension=${extensionPath}`,
      "--no-first-run",
      "--no-default-browser-check",
      "about:blank",
    ],
    {
      cwd: repoRoot,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
}

async function terminateChrome(chrome) {
  if (!chrome || chrome.exitCode !== null || chrome.signalCode !== null) {
    return;
  }

  try {
    process.kill(-chrome.pid, "SIGTERM");
  } catch (error) {
    if (error.code !== "ESRCH") {
      throw error;
    }
  }

  await new Promise((resolve) => {
    const timeout = setTimeout(resolve, 3_000);
    chrome.once("exit", () => {
      clearTimeout(timeout);
      resolve();
    });
  });

  if (chrome.exitCode === null && chrome.signalCode === null) {
    try {
      process.kill(-chrome.pid, "SIGKILL");
    } catch (error) {
      if (error.code !== "ESRCH") {
        throw error;
      }
    }
  }
}

async function removeTempProfile(userDataDir) {
  const realTemp = await fs.promises.realpath(os.tmpdir());
  const realProfileParent = await fs.promises.realpath(path.dirname(userDataDir));
  const basename = path.basename(userDataDir);

  if (realProfileParent === realTemp && basename.startsWith("lorelei-google-smoke-")) {
    await fs.promises.rm(userDataDir, { recursive: true, force: true });
  }
}

function assertResponse(response) {
  if (!response || response.ok !== true) {
    throw new Error(`Expected response.ok true, got: ${JSON.stringify(response)}`);
  }

  const title = typeof response.title === "string" ? response.title : "";
  const searchValue = typeof response.searchValue === "string" ? response.searchValue : "";
  if (searchValue !== query && !title.includes(query)) {
    throw new Error(
      `Expected searchValue to match query or title to include query, got: ${JSON.stringify({
        title,
        searchValue,
      })}`
    );
  }
}

let chrome = null;
let userDataDir = null;
let chromeStderr = "";
let hostLogPath = null;

try {
  const manifestPath = await runInstaller();
  await unlinkStaleSocket();
  userDataDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "lorelei-google-smoke-"));
  hostLogPath = await installProfileManifest(userDataDir, manifestPath);
  chrome = launchChrome(userDataDir);

  chrome.stderr.on("data", (chunk) => {
    chromeStderr += chunk.toString("utf8");
  });
  chrome.stdout.on("data", () => {});
  chrome.on("exit", (code, signal) => {
    if (code !== null && code !== 0 && chromeStderr) {
      process.stderr.write(`Chrome exited ${code} ${signal || ""}\n${chromeStderr}\n`);
    }
  });

  await waitForSocket();
  const response = await sendSocketCommand({
    id: "e2e-google",
    type: "googleSearch",
    query,
  });

  assertResponse(response);
  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      title: response.title || "",
      url: response.url || "",
      searchValue: response.searchValue || "",
    })}\n`
  );
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  if (chromeStderr.trim()) {
    process.stderr.write(`Chrome stderr:\n${chromeStderr.trim()}\n`);
  }
  if (hostLogPath && fs.existsSync(hostLogPath)) {
    const hostLog = await fs.promises.readFile(hostLogPath, "utf8");
    if (hostLog.trim()) {
      process.stderr.write(`Native host stderr:\n${hostLog.trim()}\n`);
    }
  }
  process.exitCode = 1;
} finally {
  await terminateChrome(chrome);
  if (userDataDir) {
    await removeTempProfile(userDataDir);
  }
}
