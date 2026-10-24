#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_APP="$SCRIPT_DIR/AI語音輸入.app"
PROFILE_ROOT="$HOME"
TEST_MODE=0
if [[ -n "${NEKO_INSTALL_TEST_PROFILE:-}" ]]; then
  # Disposable-profile regression tests never stop apps, change login jobs,
  # display UI or use the real user's profile.
  [[ "$NEKO_INSTALL_TEST_PROFILE" == /* && "${NEKO_INSTALL_TEST_PROFILE:A}" != "${HOME:A}" ]] || exit 1
  PROFILE_ROOT="$NEKO_INSTALL_TEST_PROFILE"
  TEST_MODE=1
fi
# Unattended installs (AI agents, `curl … | zsh`) can skip the dialogs, and
# every dialog gives up on its own so nothing waits forever for a click.
SHOW_DIALOGS=1
if (( TEST_MODE )) || [[ "${NEKO_INSTALL_NO_DIALOG:-}" == 1 ]]; then SHOW_DIALOGS=0; fi
LABEL="tw.panh.FreeVoiceType"
LAUNCH_AGENT="$PROFILE_ROOT/Library/LaunchAgents/$LABEL.plist"
TARGET_APP="$PROFILE_ROOT/Applications/AI語音輸入.app"

fail() {
  print -u2 -r -- "$1"
  if (( SHOW_DIALOGS )); then
    osascript -e 'display alert "安裝未完成" message "原本的 App 和個人設定已保留。請查看安裝視窗的說明。" as critical giving up after 120' >/dev/null || true
  fi
  exit 1
}
version_of() {
  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || true)"
  print -r -- "${short:-未知版本}（build ${build:-?}）"
}
[[ -d "$SOURCE_APP" ]] || fail '請保留解壓縮後的資料夾結構，再重新執行安裝.command。'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == "$LABEL" ]] || fail '安裝包的 App 身分不符。'
codesign --verify --deep --strict "$SOURCE_APP" || fail '安裝包簽章驗證失敗。'

# Preserve the established path, including older Application Support installs.
if [[ -f "$LAUNCH_AGENT" ]]; then
  LEGACY_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$LAUNCH_AGENT" 2>/dev/null || true)"
  if [[ "$LEGACY_TARGET" == /*.app && -d "$LEGACY_TARGET" && ( "$TEST_MODE" == 0 || "$LEGACY_TARGET" == "$PROFILE_ROOT"/* ) && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_TARGET/Contents/Info.plist" 2>/dev/null)" == "$LABEL" ]]; then
    TARGET_APP="$LEGACY_TARGET"
  fi
fi
if [[ ! -d "$TARGET_APP" ]]; then
  CANDIDATES=("$PROFILE_ROOT/Library/Application Support/AI語音輸入/AI語音輸入.app" "$PROFILE_ROOT/Applications/AI語音輸入.app")
  if (( ! TEST_MODE )); then CANDIDATES+=("/Applications/AI語音輸入.app"); fi
  for candidate in "${CANDIDATES[@]}"; do
    if [[ -d "$candidate" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null)" == "$LABEL" ]]; then
      TARGET_APP="$candidate"
      break
    fi
  done
fi
if [[ -d "$TARGET_APP" ]]; then
  REQUIREMENT="$(codesign -d -r- "$TARGET_APP" 2>/dev/null)"
  REQUIREMENT="${REQUIREMENT#designated => }"
  [[ -n "$REQUIREMENT" ]] || fail '無法讀取原版本的簽章身分。'
  codesign --verify --deep --strict --test-requirement "=$REQUIREMENT" "$SOURCE_APP" || fail '新版與原版本的簽章身分不相容；尚未替換 App。'
fi
NEW_VERSION="$(version_of "$SOURCE_APP")"
OLD_VERSION=""
if [[ -d "$TARGET_APP" ]]; then OLD_VERSION="$(version_of "$TARGET_APP")"; fi

INSTALL_DIR="${TARGET_APP:h}"
mkdir -p "$INSTALL_DIR" "$PROFILE_ROOT/Library/LaunchAgents"
STAGE="$(mktemp -d "$INSTALL_DIR/.neighbor-update.XXXXXX")"
OLD_APP="$STAGE/Previous.app"
COMMITTED=0
rollback() {
  if (( ! COMMITTED )) && [[ -d "$OLD_APP" ]]; then
    if [[ -d "$TARGET_APP" ]]; then mv "$TARGET_APP" "$STAGE/Failed.app"; fi
    mv "$OLD_APP" "$TARGET_APP"
  fi
}
trap rollback EXIT
# Stage and verify before stopping or replacing the old app. No user data,
# Keychain, UserDefaults, cat.config.json or TCC settings are modified here.
ditto "$SOURCE_APP" "$STAGE/New.app"
codesign --verify --deep --strict "$STAGE/New.app"
if (( ! TEST_MODE )); then pkill -x FreeVoiceType 2>/dev/null || true; fi
if [[ -d "$TARGET_APP" ]]; then mv "$TARGET_APP" "$OLD_APP"; fi
mv "$STAGE/New.app" "$TARGET_APP"
if [[ ! -f "$LAUNCH_AGENT" ]]; then
  /usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$LAUNCH_AGENT"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$LAUNCH_AGENT"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:0 string /usr/bin/open' "$LAUNCH_AGENT"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -gj' "$LAUNCH_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $TARGET_APP" "$LAUNCH_AGENT"
  /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$LAUNCH_AGENT"
  plutil -lint "$LAUNCH_AGENT"
  if (( ! TEST_MODE )); then launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT" 2>/dev/null || true; fi
fi
COMMITTED=1
print -r -- "Installed: $TARGET_APP"
if [[ -d "$OLD_APP" ]]; then print -r -- "Previous app backup: $OLD_APP"; else rmdir "$STAGE"; fi
if [[ -z "$OLD_VERSION" ]]; then
  print -r -- "安裝類型：全新安裝 $NEW_VERSION"
elif [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  print -r -- "安裝類型：重新安裝同一版 $NEW_VERSION"
else
  print -r -- "安裝類型：更新 $OLD_VERSION → $NEW_VERSION"
fi
print -r -- "安裝工具沒有修改 API Key、偏好設定、剪貼簿歷史與貓咪設定。"
if [[ -d "$OLD_APP" ]]; then print -r -- "確認新版正常後，可以把舊版備份資料夾丟到垃圾桶：$STAGE"; fi
if (( ! TEST_MODE )); then
  open "$TARGET_APP" || true
  if (( SHOW_DIALOGS )); then
    osascript -e 'display dialog "安裝完成！既有 API Key、快捷鍵與貓咪設定會保留。\n\n首次使用請在 App 內設定 Groq API Key，並允許麥克風與輔助使用權限。之後收到新版通知時，可自行決定是否更新。" buttons {"好"} default button "好" with title "AI 語音輸入" giving up after 120' >/dev/null || true
  fi
fi
