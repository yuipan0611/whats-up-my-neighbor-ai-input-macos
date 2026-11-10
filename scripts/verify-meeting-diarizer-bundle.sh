#!/bin/zsh
#
# 驗證 App 內的說話者辨識輔助工具（由 scripts/build.sh 在簽章後呼叫，也可單獨執行）：
#   用法：scripts/verify-meeting-diarizer-bundle.sh "build/AI語音輸入.app"
#
# 為什麼要逐一驗：外層 App 的 codesign 沒有 --deep，巢狀程式碼必須各自簽好；
# 沒簽、簽錯身分、或簽完又被改動，都要在這裡就失敗，而不是到使用者機器上才發現。
set -euo pipefail

APP="${1:?usage: $0 <App.app>}"
HELPER="$APP/Contents/Helpers/meeting-diarizer"
FRAMEWORKS="$APP/Contents/Frameworks"
DYLIBS=("$FRAMEWORKS/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS/libonnxruntime.dylib")

fail() { print -u2 "meeting-diarizer bundle check FAILED: $1"; exit 1; }

# 1. 位置：Helpers 放命令列工具、Frameworks 放 dylib。
[[ -f "$HELPER" && -x "$HELPER" ]] || fail "missing or non-executable helper: $HELPER"
for dylib in "${DYLIBS[@]}"; do [[ -f "$dylib" ]] || fail "missing dylib: $dylib"; done

# 2. 架構：只有 arm64（Intel 上功能由 MeetingDiarizerLocator 停用）。
for item in "$HELPER" "${DYLIBS[@]}"; do
  [[ "$(lipo -archs "$item")" == "arm64" ]] || fail "${item:t} must be arm64 only, got: $(lipo -archs "$item")"
done

# 3. rpath：helper 到 ../Frameworks 找 dylib，不能還指著建置用的 ../lib。
rpaths="$(otool -l "$HELPER" | awk '/cmd LC_RPATH/ {f=1} f && /path / {print $2; f=0}')"
[[ "$rpaths" == *"@executable_path/../Frameworks"* ]] || fail "helper rpath lacks @executable_path/../Frameworks (has: ${rpaths//$'\n'/ })"
[[ "$rpaths" != *"@executable_path/../lib"* ]] || fail "helper still has the build-time rpath @executable_path/../lib"
# helper 與 dylib 依賴的 @rpath 函式庫，都要在 Frameworks 裡找得到。
for item in "$HELPER" "${DYLIBS[@]}"; do
  for dependency in $(otool -L "$item" | awk '/@rpath\// {print $1}'); do
    name="${dependency#@rpath/}"
    [[ "$name" == "${item:t}" || -f "$FRAMEWORKS/$name" ]] || fail "${item:t} needs $dependency but $FRAMEWORKS/$name is missing"
  done
done

# 4. 逐一驗證簽章（不靠 --deep）。
for item in "${DYLIBS[@]}" "$HELPER"; do
  codesign --verify --strict --verbose=1 "$item" 2>&1 | sed "s|^|  ${item:t}: |" || true
  codesign --verify --strict "$item" 2>/dev/null || fail "${item:t} signature is missing or invalid"
done
# 先存進變數再比對：pipefail 下，grep -q 提早結束會讓 codesign 吃 SIGPIPE 而被誤判為失敗。
helper_info="$(codesign -dv "$HELPER" 2>&1)"
[[ "$helper_info" == *"Identifier=tw.panh.FreeVoiceType.meeting-diarizer"* ]] \
  || fail "helper signing identifier is not tw.panh.FreeVoiceType.meeting-diarizer"

# 5. 與外層 App 同一個簽章身分（本機 ad-hoc 就都是 ad-hoc；正式簽章要是同一張憑證）。
signer_of() {
  local item="$1" directory info; directory="$(mktemp -d)"
  info="$(codesign -dv "$item" 2>&1)"
  if [[ "$info" == *"Signature=adhoc"* ]]; then
    print adhoc
  else
    codesign -d --extract-certificates="$directory/cert" "$item" >/dev/null 2>&1
    shasum -a 1 "$directory/cert0" | cut -d' ' -f1
  fi
  rm -rf "$directory"
}
app_signer="$(signer_of "$APP")"
for item in "${DYLIBS[@]}" "$HELPER"; do
  [[ "$(signer_of "$item")" == "$app_signer" ]] || fail "${item:t} is signed by a different identity than the app"
done

# 6. 整個 App（含巢狀程式碼）嚴格驗證：簽完之後沒有被改動。
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "app does not pass codesign --deep --strict"

# 7. 冒煙測試（只在 Apple Silicon 主機）：不帶參數執行，應該印出參數錯誤並以 2 結束；
#    如果 dylib 載不進來，dyld 會讓它以訊號結束（> 128）或印出 "Library not loaded"。
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || print 0)" == 1 ]]; then
  set +e
  output="$("$HELPER" 2>&1 >/dev/null)"
  code=$?
  set -e
  [[ "$output" != *"Library not loaded"* ]] || fail "dyld could not load a library: $output"
  [[ $code -eq 2 ]] || fail "helper exited with $code instead of 2 (argument error); output: $output"
  [[ "$output" == error:* ]] || fail "unexpected helper output: $output"
else
  print "  (skipping the launch check: this host is not Apple Silicon)"
fi

print "meeting-diarizer bundle verified: helper + ${#DYLIBS[@]} dylibs, arm64, signed individually by the same identity as the app"
