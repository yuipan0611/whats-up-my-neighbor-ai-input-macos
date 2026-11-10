#!/bin/zsh
# 會議說話者辨識（M2）的離線測試：協調器（假的 Process 執行器）、對帳純函式、frontmatter、
# 真的 Process 執行器（/bin/sh 小腳本）。不需要 sherpa、模型、音檔或網路。
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/MeetingDiarizationTests"

mkdir -p "$ROOT/build"

swiftc \
  -swift-version 5 \
  -framework AppKit \
  "$ROOT/Sources/GroqVoiceInput/LanguagePolicy.swift" \
  "$ROOT/Sources/GroqVoiceInput/TextPostProcessor.swift" \
  "$ROOT/Sources/GroqVoiceInput/DictationCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingStore.swift" \
  "$ROOT/Sources/GroqVoiceInput/SpeakerAligner.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationFiles.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationCoordinator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerProcess.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingAudio.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerLocator.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerAssets.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizerDownloadText.swift" \
  "$ROOT/Sources/GroqVoiceInput/MeetingDiarizationDialogs.swift" \
  "$ROOT/Tests/MeetingDiarizationTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
