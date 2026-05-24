# Lorelei Chrome Native Host

This directory contains the development native messaging host for the Lorelei Chrome bridge.

## Check

Run:

```sh
node native-host/lorelei_chrome_native_host.js --check
```

Expected output is a JSON line with `ok: true`, the native host name, and the Unix domain socket path.

## Install Development Manifest

From the repository root, run:

```sh
native-host/install-dev-host.sh EXTENSION_ID
```

The installer writes the Chrome native messaging manifest to:

```text
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.devtaishi.lorelei.chrome_bridge.json
```

For the current development extension, run:

```sh
native-host/install-dev-host.sh eaiefhpgoknofichehnpopdjbhlolech
```

## Protocol

The host starts a Unix domain socket at:

```text
/tmp/lorelei-chrome-bridge-<uid>.sock
```

Set `LORELEI_CHROME_BRIDGE_SOCKET` to override the path.

Lorelei sends newline-delimited JSON requests to the socket. The host forwards each request to Chrome as a native messaging frame. Chrome responses with a matching string `id` are returned to the socket as newline-delimited JSON and the socket is closed.

## Google E2E Smoke Test

Run the Google-only end-to-end smoke test from the repository root:

```sh
node native-host/e2e-google-smoke.mjs
```

The script installs the development native host manifest for the local bridge extension, launches Google Chrome with a temporary profile and the unpacked extension, sends a `googleSearch` command over the Unix socket, and verifies that Google receives the smoke-test query. It only opens Google Search and prints a JSON success line with the observed title, URL, and search value.
