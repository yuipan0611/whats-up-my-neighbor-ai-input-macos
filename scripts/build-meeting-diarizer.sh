#!/bin/zsh
# 建置說話者辨識原型 meeting-diarizer。原型只做 arm64；universal 留到發布前再決定
# （做法與 build.sh 相同：各架構各編一次再 lipo，sherpa 的 dylib 本來就是 universal）。
# 輸出：build/meeting-diarizer/{bin,lib}，以及 build/meeting-diarizer/assets/models。
set -euo pipefail

ROOT="${0:A:h:h}"
ASSETS="$("$ROOT/scripts/fetch-meeting-diarizer-assets.sh" | tail -1)"
OUT="$ROOT/build/meeting-diarizer"
SRC="$ROOT/Tools/MeetingDiarizer"
LIB="$ASSETS/sherpa/lib"

rm -rf "$OUT/bin" "$OUT/lib" "$OUT/obj"
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/obj"

for architecture in arm64; do
  swiftc \
    -target "$architecture-apple-macos13.0" \
    -swift-version 5 \
    -O \
    -framework AVFoundation \
    -import-objc-header "$ASSETS/SherpaOnnx-Bridging-Header.h" \
    -Xcc "-I$ASSETS/sherpa/include" \
    -L "$LIB" -lsherpa-onnx-c-api \
    -Xlinker -rpath -Xlinker @executable_path/../lib \
    "$SRC"/*.swift "$ROOT/Sources/GroqVoiceInput/SpeakerAligner.swift" "$ASSETS/SherpaOnnx.swift" \
    -o "$OUT/obj/meeting-diarizer-$architecture"
done
cp "$OUT/obj/meeting-diarizer-arm64" "$OUT/bin/meeting-diarizer"
for dylib in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
  lipo "$LIB/$dylib" -thin arm64 -output "$OUT/lib/$dylib"
done

# 公證前必須用 App 的簽章身分重簽；原型階段只做 ad-hoc 簽章，讓本機可執行。
codesign --force --sign - "$OUT/lib/libsherpa-onnx-c-api.dylib" "$OUT/lib/libonnxruntime.dylib" "$OUT/bin/meeting-diarizer" 2>/dev/null

print -- "built $OUT/bin/meeting-diarizer ($(lipo -archs "$OUT/bin/meeting-diarizer"))"
