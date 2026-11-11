#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/MeetingDiarizerDownloaderTests"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerAssets.swift" \
  "$ROOT/Sources/GroqVoiceInput/SafeFileRemoval.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerDownloader.swift" \
  "$ROOT/Tests/MeetingDiarizerDownloaderTests.swift" \
  -o "$OUTPUT"
exec "$OUTPUT"
