const HOST_NAME = "com.devtaishi.lorelei.chrome_bridge";
const RECONNECT_DELAY_MS = 1000;
const TAB_LOAD_TIMEOUT_MS = 15000;

let nativePort = null;
let reconnectTimer = null;

function connectNativeHost() {
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  try {
    nativePort = chrome.runtime.connectNative(HOST_NAME);
    nativePort.onMessage.addListener(handleHostMessage);
    nativePort.onDisconnect.addListener(handleDisconnect);
    postToHost({ type: "ready" });
  } catch (error) {
    nativePort = null;
    scheduleReconnect();
  }
}

function handleDisconnect() {
  nativePort = null;
  scheduleReconnect();
}

function scheduleReconnect() {
  if (reconnectTimer !== null) {
    return;
  }

  reconnectTimer = setTimeout(connectNativeHost, RECONNECT_DELAY_MS);
}

function postToHost(message) {
  if (!nativePort) {
    return;
  }

  try {
    nativePort.postMessage(message);
  } catch (error) {
    nativePort = null;
    scheduleReconnect();
  }
}

function handleHostMessage(message) {
  if (message?.type === "hostReady") {
    postToHost({ type: "ready" });
    return;
  }

  handleCommand(message);
}

async function handleCommand(message) {
  if (typeof message?.id !== "string") {
    return;
  }

  try {
    if (message.type === "ping") {
      postToHost({ id: message.id, ok: true, type: "ping" });
      return;
    }

    if (message.type === "googleSearch") {
      const result = await googleSearch(message.query);
      postToHost({
        id: message.id,
        ok: true,
        type: "googleSearch",
        ...result,
      });
      return;
    }

    postToHost({
      id: message.id,
      ok: false,
      type: message.type,
      error: "Unsupported command",
    });
  } catch (error) {
    postToHost({
      id: message.id,
      ok: false,
      type: message.type,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

async function googleSearch(query) {
  const trimmedQuery = typeof query === "string" ? query.trim() : "";
  if (!trimmedQuery) {
    throw new Error("Query must be a non-empty string");
  }

  const tab = await chrome.tabs.create({
    active: true,
    url: `https://www.google.com/search?q=${encodeURIComponent(trimmedQuery)}`,
  });

  if (typeof tab.id !== "number") {
    throw new Error("Created tab did not include an id");
  }

  await waitForTabComplete(tab.id);

  const [injectionResult] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: () => {
      const searchInput = document.querySelector("textarea[name='q'], input[name='q']");

      return {
        title: document.title,
        url: location.href,
        searchValue: searchInput instanceof HTMLTextAreaElement || searchInput instanceof HTMLInputElement
          ? searchInput.value
          : "",
      };
    },
  });

  return injectionResult?.result ?? { title: "", url: "", searchValue: "" };
}

function waitForTabComplete(tabId) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timeoutId = null;

    const cleanup = () => {
      chrome.tabs.onUpdated.removeListener(onUpdated);
      if (timeoutId !== null) {
        clearTimeout(timeoutId);
      }
    };

    const finish = () => {
      if (settled) {
        return;
      }

      settled = true;
      cleanup();
      resolve();
    };

    const fail = (error = new Error("Timed out waiting for tab to load")) => {
      if (settled) {
        return;
      }

      settled = true;
      cleanup();
      reject(error);
    };

    const onUpdated = (updatedTabId, changeInfo) => {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        finish();
      }
    };

    chrome.tabs.onUpdated.addListener(onUpdated);
    timeoutId = setTimeout(fail, TAB_LOAD_TIMEOUT_MS);

    chrome.tabs.get(tabId, (tab) => {
      if (chrome.runtime.lastError) {
        fail(new Error(chrome.runtime.lastError.message));
        return;
      }

      if (tab.status === "complete") {
        finish();
      }
    });
  });
}

connectNativeHost();
