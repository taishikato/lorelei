#!/usr/bin/env bash
# Snapshot the app-server protocol schema for the installed codex CLI.
# Re-run after every codex upgrade and review the diff against the Swift
# protocol layer (CodexAppServerProtocol.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/appserver-schema
codex app-server generate-json-schema --out docs/appserver-schema
codex --version > docs/appserver-schema/CODEX_VERSION
