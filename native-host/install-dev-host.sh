#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PATH="$ROOT_DIR/native-host/lorelei_chrome_native_host.js"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/com.devtaishi.lorelei.chrome_bridge.json"
EXTENSION_ID="${1:-}"

if [[ -z "$EXTENSION_ID" ]]; then
  echo "Usage: $0 EXTENSION_ID" >&2
  exit 1
fi

chmod +x "$HOST_PATH"
mkdir -p "$MANIFEST_DIR"

cat > "$MANIFEST_PATH" <<JSON
{
  "name": "com.devtaishi.lorelei.chrome_bridge",
  "description": "Lorelei Chrome native messaging bridge",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXTENSION_ID/"
  ]
}
JSON

echo "$MANIFEST_PATH"
