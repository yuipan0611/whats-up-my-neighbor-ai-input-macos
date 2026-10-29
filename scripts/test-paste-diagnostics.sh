#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/PasteDiagnosticsTests"

mkdir -p "$ROOT/build"
swiftc -swift-version 5 \
  "$ROOT/Sources/GroqVoiceInput/PasteDiagnostics.swift" \
  "$ROOT/Sources/GroqVoiceInput/RemoteTargetValidationPolicy.swift" \
  "$ROOT/Sources/GroqVoiceInput/FocusTargetService.swift" \
  "$ROOT/Sources/GroqVoiceInput/DictationFocusTrace.swift" \
  "$ROOT/Sources/GroqVoiceInput/TextInsertionService.swift" \
  "$ROOT/Tests/PasteDiagnosticsTests.swift" \
  -o "$OUTPUT"

exec env -u NEIGHBOR_PASTE_DIAGNOSTICS_PATH "$OUTPUT"
