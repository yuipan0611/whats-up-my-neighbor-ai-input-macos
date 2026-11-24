#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 -framework AppKit "$ROOT/Sources/GroqVoiceInput/VPSCatDropHint.swift" "$ROOT/Sources/GroqVoiceInput/VPSCatTransferZone.swift" \
  "$ROOT/Tests/VPSCatTransferZoneTests.swift" -o "$ROOT/build/VPSCatTransferZoneTests"
"$ROOT/build/VPSCatTransferZoneTests"
