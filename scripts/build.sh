#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/build/AI語音輸入.app"
SPARKLE_ROOT="$("$ROOT/scripts/fetch-sparkle.sh")"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources" "$OUTPUT/Contents/Frameworks"
cp "$ROOT/Resources/Info.plist" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/Resources/OldAppCleanup.zsh" "$OUTPUT/Contents/Resources/OldAppCleanup.zsh"
cp "$ROOT/Resources/AppIcon.icns" "$OUTPUT/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/neko-base.png" "$OUTPUT/Contents/Resources/neko-base.png"
ditto "$ROOT/Resources/DesktopPet" "$OUTPUT/Contents/Resources/DesktopPet"
ditto "$ROOT/Resources/VPSDesktop" "$OUTPUT/Contents/Resources/VPSDesktop"
cp "$ROOT/cat.config.json" "$ROOT/CAT-CONFIG.md" "$OUTPUT/Contents/Resources/"
cp "$SPARKLE_ROOT/LICENSE" "$OUTPUT/Contents/Resources/Sparkle-LICENSE.txt"
ditto "$SPARKLE_ROOT/Sparkle.framework" "$OUTPUT/Contents/Frameworks/Sparkle.framework"

# CI supplies version metadata to the output bundle, never to tracked sources.
if [[ -n "${RELEASE_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$OUTPUT/Contents/Info.plist"
fi
if [[ -n "${RELEASE_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$OUTPUT/Contents/Info.plist"
fi

# Identify the exact QA installer without changing the published version or
# letting development metadata enter the separately signed release build.
if [[ "${RELEASE_SIGNING:-0}" != 1 && -n "${NEKO_DEVELOPMENT_REVISION:-}" ]]; then
  [[ "$NEKO_DEVELOPMENT_REVISION" =~ '^[a-fA-F0-9]{40}$' ]] || { print -u2 'Invalid development revision'; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :NekoDevelopmentRevision string $NEKO_DEVELOPMENT_REVISION" "$OUTPUT/Contents/Info.plist"
fi

SOURCES=("$ROOT"/Sources/GroqVoiceInput/*.swift)

for architecture in arm64 x86_64; do
swiftc \
  -target "$architecture-apple-macos13.0" \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework QuartzCore \
  -framework CoreAudio \
  -framework Carbon \
  -framework Security \
  -framework MultipeerConnectivity \
  -framework UserNotifications \
  -framework SwiftUI \
  -framework WebKit \
  -F "$SPARKLE_ROOT" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${SOURCES[@]}" \
  -o "$ROOT/build/FreeVoiceType-$architecture"
done
lipo -create "$ROOT/build/FreeVoiceType-arm64" "$ROOT/build/FreeVoiceType-x86_64" \
  -output "$OUTPUT/Contents/MacOS/FreeVoiceType"

# 說話者辨識輔助工具（預設關閉的功能用到它；僅 arm64，Intel Mac 上功能自動停用）。
# 位置依 Apple 對 bundle 內容的慣例：命令列工具放 Contents/Helpers，它依賴的 dylib 放 Contents/Frameworks。
# 這些是「巢狀程式碼」：外層 App 的 codesign 沒有 --deep，所以下面的簽章段會由內而外逐一明確簽
# （dylib → helper → App），最後再逐一驗證。模型不進 App，由 App 第一次使用時下載。
# BUNDLE_MEETING_DIARIZER=0 可略過（離線開發用）；略過時 App 內沒有 helper，功能自動不可用。
MEETING_DIARIZER_HELPER=""
MEETING_DIARIZER_DYLIBS=()
if [[ "${BUNDLE_MEETING_DIARIZER:-1}" == 1 ]]; then
  MEETING_DIARIZER_SKIP_MODELS=1 "$ROOT/scripts/build-meeting-diarizer.sh"
  DIARIZER_BUILD="$ROOT/build/meeting-diarizer"
  mkdir -p "$OUTPUT/Contents/Helpers"
  cp "$DIARIZER_BUILD/bin/meeting-diarizer" "$OUTPUT/Contents/Helpers/meeting-diarizer"
  for dylib in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
    cp "$DIARIZER_BUILD/lib/$dylib" "$OUTPUT/Contents/Frameworks/$dylib"
    MEETING_DIARIZER_DYLIBS+=("$OUTPUT/Contents/Frameworks/$dylib")
  done
  # build-meeting-diarizer.sh 讓 helper 到 ../lib 找 dylib；在 App 裡 dylib 在 ../Frameworks。
  install_name_tool -rpath @executable_path/../lib @executable_path/../Frameworks \
    "$OUTPUT/Contents/Helpers/meeting-diarizer"
  MEETING_DIARIZER_HELPER="$OUTPUT/Contents/Helpers/meeting-diarizer"
fi

# 巢狀程式碼由內而外簽章：先 dylib（葉節點），再 helper。身分與選項和外層 App 完全相同，
# 外層 App 之後再簽（它的簽章會封存這些檔案的雜湊）。沒有 helper 時什麼都不做。
sign_meeting_diarizer() {
  [[ -n "$MEETING_DIARIZER_HELPER" ]] || return 0
  local identity="$1"; shift
  codesign --force --timestamp=none --sign "$identity" "$@" "${MEETING_DIARIZER_DYLIBS[@]}"
  codesign --force --timestamp=none --sign "$identity" "$@" \
    --identifier tw.panh.FreeVoiceType.meeting-diarizer "$MEETING_DIARIZER_HELPER"
}

if [[ "${RELEASE_SIGNING:-0}" == 1 ]]; then
  : "${MAC_CODESIGN_IDENTITY:?Release requires a stable signing certificate}"
  : "${MACOS_SIGNING_SHA1:?Release requires a pinned signing fingerprint}"
  [[ "$MAC_CODESIGN_IDENTITY" == "$MACOS_SIGNING_SHA1" && "$MACOS_SIGNING_SHA1" =~ '^[A-F0-9]{40}$' ]] || { print -u2 'Release signing identity must match the pinned certificate'; exit 1; }
  SIGNING_OPTIONS=()
  if [[ -n "${MAC_CODESIGN_KEYCHAIN:-}" ]]; then
    SIGNING_OPTIONS+=(--keychain "$MAC_CODESIGN_KEYCHAIN")
  fi
  # Free distribution uses an existing stable certificate, without notarization
  # or Hardened Runtime. Retain Sparkle's vendor-signed nested code and the
  # installed app's designated requirement. Never fall back to ad-hoc releases.
  sign_meeting_diarizer "$MAC_CODESIGN_IDENTITY" "${SIGNING_OPTIONS[@]}"
  codesign --force --timestamp=none --sign "$MAC_CODESIGN_IDENTITY" "${SIGNING_OPTIONS[@]}" \
    --requirements '=designated => identifier "tw.panh.FreeVoiceType"' "$OUTPUT"
  python3 "$ROOT/scripts/validate-signing.py" "$OUTPUT" "$MACOS_SIGNING_SHA1"
else
  # Preserve the established designated requirement for local installs.
  sign_meeting_diarizer "${MAC_CODESIGN_IDENTITY:--}"
  codesign --force --timestamp=none --sign "${MAC_CODESIGN_IDENTITY:--}" \
    --requirements '=designated => identifier "tw.panh.FreeVoiceType"' "$OUTPUT"
fi

codesign --verify --deep --strict --verbose=2 "$OUTPUT"
if [[ -n "$MEETING_DIARIZER_HELPER" ]]; then
  "$ROOT/scripts/verify-meeting-diarizer-bundle.sh" "$OUTPUT"
fi
echo "Built: $OUTPUT"
