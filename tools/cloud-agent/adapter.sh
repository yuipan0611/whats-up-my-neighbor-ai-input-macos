#!/usr/bin/env bash
set -euo pipefail
exec python3 /app/codex_adapter.py "$1" "$2"
