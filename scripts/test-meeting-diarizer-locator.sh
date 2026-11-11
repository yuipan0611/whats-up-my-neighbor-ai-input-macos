#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/MeetingDiarizerLocatorTests"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerAssets.swift" \
  "$ROOT/Sources/GroqVoiceInput/SafeFileRemoval.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerLocator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerDownloadText.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerDownloader.swift" \
  "$ROOT/Tests/MeetingDiarizerLocatorTests.swift" \
  -o "$OUTPUT"
exec "$OUTPUT"
