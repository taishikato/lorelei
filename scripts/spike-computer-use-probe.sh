#!/bin/bash
# Read-only reachability probes for the Codex Computer Use plugin.
# Stages: handshake | list-apps | plugins | all (default: handshake)
# Never calls any mutating tool; the only tool invocation issued is list_apps.
set -euo pipefail

STAGE="${1:-handshake}"

PLUGIN_BASE="$HOME/.codex/plugins/cache/openai-bundled/computer-use"
BUNDLED_CODEX="/Applications/ChatGPT.app/Contents/Resources/codex"

fail() { echo "$1" >&2; exit 1; }

plugin_root() {
  [ -d "$PLUGIN_BASE" ] || fail "PROBE: plugin cache not found at $PLUGIN_BASE"
  # Highest version directory wins.
  local latest
  latest=$(ls "$PLUGIN_BASE" | sort -V | tail -n 1)
  [ -n "$latest" ] || fail "PROBE: no version directories under $PLUGIN_BASE"
  echo "$PLUGIN_BASE/$latest"
}

MCP_REL="Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

with_timeout() { # with_timeout SECONDS cmd args...
  perl -e 'alarm shift; exec @ARGV' "$@"
}

mcp_send() { # mcp_send TIMEOUT_SECONDS EXTRA_REQUEST_JSON...
  local timeout_s="$1"; shift
  local root
  root=$(plugin_root)
  [ -x "$root/$MCP_REL" ] || fail "PROBE: MCP binary missing at $root/$MCP_REL"
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lorelei-spike","version":"0.0.1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    for req in "$@"; do printf '%s\n' "$req"; done
    # Keep stdin open long enough for slow replies; alarm still bounds us.
    sleep "$timeout_s"
  } | (cd "$root" && with_timeout "$timeout_s" "./$MCP_REL" mcp) || true
}

stage_handshake() {
  local out
  out=$(mcp_send 15 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  if echo "$out" | grep -q '"list_apps"'; then
    echo "HANDSHAKE: OK"
    echo "$out" | grep -o '"name":"[a-z_]*"' | sort -u
  else
    echo "HANDSHAKE: FAILED"
    echo "$out"
  fi
}

stage_list_apps() {
  local out
  out=$(mcp_send 30 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}')
  if echo "$out" | grep -q '"id":2.*"result"'; then
    echo "LIST_APPS: OK"
    echo "$out" | tail -n 1 | head -c 2000
  elif echo "$out" | grep -q '"id":2.*"error"'; then
    echo "LIST_APPS: ERROR"
    echo "$out" | tail -n 1
  else
    echo "LIST_APPS: TIMEOUT (no reply to id 2 within 30s; initialize reply presence below)"
    echo "$out" | head -c 500
  fi
}

stage_plugins() {
  [ -x "$BUNDLED_CODEX" ] || fail "PROBE: bundled codex not found at $BUNDLED_CODEX"
  echo "PLUGINS: codex version: $("$BUNDLED_CODEX" --version)"
  local out
  out=$({
    printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"lorelei-spike","title":"Lorelei Spike","version":"0.0.1"},"capabilities":{"experimentalApi":true}}}'
    printf '%s\n' '{"method":"initialized"}'
    printf '%s\n' '{"id":2,"method":"plugin/list","params":{}}'
    printf '%s\n' '{"id":3,"method":"plugin/installed","params":{}}'
    sleep 20
  } | with_timeout 25 "$BUNDLED_CODEX" app-server 2>/dev/null) || true
  echo "PLUGINS: raw responses:"
  echo "$out" | grep -E '"id":(2|3)' || { echo "PLUGINS: NO REPLY to plugin/list or plugin/installed"; echo "$out" | head -c 1000; }
}

case "$STAGE" in
  handshake) stage_handshake ;;
  list-apps) stage_list_apps ;;
  plugins)   stage_plugins ;;
  all)       stage_handshake; echo; stage_list_apps; echo; stage_plugins ;;
  *) fail "usage: $0 [handshake|list-apps|plugins|all]" ;;
esac
