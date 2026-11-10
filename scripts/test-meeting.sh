#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/MeetingTests"

mkdir -p "$ROOT/build"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/GroqVoiceInput/LanguagePolicy.swift" \
  "$ROOT/Sources/GroqVoiceInput/TextPostProcessor.swift" \
  "$ROOT/Sources/GroqVoiceInput/DictationCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/GroqTranscriptionClient.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingAudio.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingStore.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationFiles.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingGroqTranscriber.swift" \
  "$ROOT/Tests/MeetingTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
