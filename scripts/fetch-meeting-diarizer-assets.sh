#!/bin/zsh
# 下載說話者辨識原型需要的第三方檔案到 build/meeting-diarizer/cache，並驗證 SHA256。
# 這些檔案**不進 repo**（build/ 已被 .gitignore 排除）。
# 輸出（stdout 最後一行）：assets 根目錄路徑。
set -euo pipefail

ROOT="${0:A:h:h}"
ASSETS="$ROOT/build/meeting-diarizer/assets"
CACHE="$ROOT/build/meeting-diarizer/cache"
mkdir -p "$ASSETS" "$CACHE"

SHERPA_TAG="v2.0.1"
GITHUB="https://github.com/k2-fsa/sherpa-onnx/releases/download"
RAW="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$SHERPA_TAG/swift-api-examples"
SRC_RAW="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$SHERPA_TAG/sherpa-onnx"

# 名稱|網址|SHA256
typeset -a ITEMS=(
  "sherpa-lib.tar.bz2|$GITHUB/$SHERPA_TAG/sherpa-onnx-$SHERPA_TAG-osx-universal2-shared-no-tts-lib.tar.bz2|242b0593a033456e9344a76a11713d1c55da794d0e37eabf6acabaf7beeb2b36"
  "SherpaOnnx.swift|$RAW/SherpaOnnx.swift|559bdc1485aecba960ca057b95e5bfd93ce7dc772d779a6c768b51ea5bcc1197"
  "SherpaOnnx-Bridging-Header.h|$RAW/SherpaOnnx-Bridging-Header.h|a49bee09fe3836844332ac523c5ff1e5a81d9a34be4fe10fbc01f0195fe0b4bc"
  "c-api.h|$SRC_RAW/c-api/c-api.h|5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f"
  "pyannote-segmentation.tar.bz2|$GITHUB/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2|24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488"
  "speaker-embedding.onnx|$GITHUB/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx|aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"
)

# MEETING_DIARIZER_SKIP_MODELS=1：只要 sherpa 函式庫與標頭（打包 App 用）。模型不進 App，
# 由 App 在第一次使用時下載（MeetingDiarizerDownloader），所以打包時不必下載這 35 MB。
SKIP_MODELS="${MEETING_DIARIZER_SKIP_MODELS:-0}"

for item in "${ITEMS[@]}"; do
  name="${item%%|*}"; rest="${item#*|}"; url="${rest%%|*}"; expected="${rest##*|}"
  if [[ "$SKIP_MODELS" == 1 && ( "$name" == pyannote-segmentation.tar.bz2 || "$name" == speaker-embedding.onnx ) ]]; then
    continue
  fi
  target="$CACHE/$name"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$expected" ]]; then
    continue
  fi
  print -u2 "downloading $name"
  curl -fsSL --retry 3 -o "$target.part" "$url"
  actual="$(shasum -a 256 "$target.part" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$target.part"
    print -u2 "SHA256 mismatch for $name: expected $expected, got $actual"
    exit 1
  fi
  mv "$target.part" "$target"
done

# 解壓
if [[ ! -d "$ASSETS/sherpa" ]]; then
  rm -rf "$ASSETS/sherpa.tmp" && mkdir -p "$ASSETS/sherpa.tmp"
  tar xjf "$CACHE/sherpa-lib.tar.bz2" -C "$ASSETS/sherpa.tmp" --strip-components=1
  mv "$ASSETS/sherpa.tmp" "$ASSETS/sherpa"
fi
if [[ "$SKIP_MODELS" != 1 ]]; then
  if [[ ! -f "$ASSETS/models/pyannote-segmentation/model.onnx" ]]; then
    rm -rf "$ASSETS/models" && mkdir -p "$ASSETS/models/pyannote-segmentation"
    tar xjf "$CACHE/pyannote-segmentation.tar.bz2" -C "$ASSETS/models/pyannote-segmentation" --strip-components=1
  fi
  cp "$CACHE/speaker-embedding.onnx" "$ASSETS/models/speaker-embedding.onnx"
fi
# 預編譯庫不含標頭檔，標頭取自同一個 tag 的原始碼
mkdir -p "$ASSETS/sherpa/include/sherpa-onnx/c-api"
cp "$CACHE/c-api.h" "$ASSETS/sherpa/include/sherpa-onnx/c-api/c-api.h"
cp "$CACHE/SherpaOnnx.swift" "$CACHE/SherpaOnnx-Bridging-Header.h" "$ASSETS/"
print -- "$ASSETS"
