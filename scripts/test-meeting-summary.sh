#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/MeetingSummarizerTests"

mkdir -p "$ROOT/build"

swiftc \
  -swift-version 5 \
  -framework Security \
  "$ROOT/Sources/GroqVoiceInput/GroqTranscriptionClient.swift" \
  "$ROOT/Sources/GroqVoiceInput/KeychainStore.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingAudio.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingStore.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationFiles.swift" \
  "$ROOT/Sources/GroqVoiceInput/GroqModelSelector.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingSummarizer.swift" \
  "$ROOT/Tests/MeetingSummarizerTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
