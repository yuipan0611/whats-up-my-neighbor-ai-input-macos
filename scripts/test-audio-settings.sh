#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/AudioSettingsTests"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 -framework AVFoundation \
  "$ROOT/Sources/GroqVoiceInput/LanguagePolicy.swift" \
  "$ROOT/Sources/GroqVoiceInput/TextPostProcessor.swift" \
  "$ROOT/Sources/GroqVoiceInput/DictationCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/GroqTranscriptionClient.swift" \
  "$ROOT/Sources/GroqVoiceInput/PinnedMicrophoneRecorder.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingAudio.swift" \
  "$ROOT/Tests/AudioSettingsTests.swift" \
  -o "$OUTPUT"
exec "$OUTPUT"
