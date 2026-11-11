#!/bin/zsh
# 說話者辨識原型的純函式測試（段檔時間軸、manifest、對齊演算法）。不需要 sherpa、模型或網路。
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/MeetingDiarizationCoreTests"

mkdir -p "$ROOT/build"

swiftc \
  -swift-version 5 \
  "$ROOT/Tools/MeetingDiarizer/ChunkTimeline.swift" \
  "$ROOT/Tools/MeetingDiarizer/MeetingManifest.swift" \
  "$ROOT/Tools/MeetingDiarizer/SpeakerAligner.swift" \
  "$ROOT/Tests/MeetingDiarizationCoreTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
