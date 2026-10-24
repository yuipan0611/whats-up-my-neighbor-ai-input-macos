#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_APP="$SCRIPT_DIR/AI語音輸入.app"
FIRST_CAT="$SCRIPT_DIR/FirstCat.nekocatsetup"
HAS_FIRST_CAT=0
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
CAT_DATA_DIR="$PROFILE_ROOT/Library/Application Support/$LABEL"
CAT_INBOX="$CAT_DATA_DIR/IncomingCats"
PENDING_CAT=""
PENDING_TEMP=""

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

# A custom delivery carries data beside the signed app. The app validates the
# ZIP itself and imports it in the logged-in user's context. Refuse special or
# oversized files before replacing a working app; never unpack them here.
if [[ -e "$FIRST_CAT" || -L "$FIRST_CAT" ]]; then
  [[ -f "$FIRST_CAT" && ! -L "$FIRST_CAT" ]] || fail '客製貓咪包必須是一般檔案；原本的 App 尚未變動。'
  FIRST_CAT_BYTES="$(/usr/bin/stat -f %z "$FIRST_CAT")"
  (( FIRST_CAT_BYTES > 0 && FIRST_CAT_BYTES <= 1048576 )) || fail '客製貓咪包大小無效；請使用 1 MiB 以內的外觀包。'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NekoCatPackSchemaVersion' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)" == 1 ]] || fail '安裝包內的 App 尚未支援貓咪包；原本的 App 尚未變動。'
  for directory in "$PROFILE_ROOT/Library" "$PROFILE_ROOT/Library/Application Support" "$CAT_DATA_DIR" "$CAT_INBOX"; do
    [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || fail '貓咪資料目錄必須是一般資料夾；原本的 App 尚未變動。'
  done
  HAS_FIRST_CAT=1
fi

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
  if (( ! COMMITTED )); then
    if [[ -n "$PENDING_TEMP" ]]; then rm -f "$PENDING_TEMP"; fi
    if [[ -n "$PENDING_CAT" ]]; then rm -f "$PENDING_CAT"; fi
    if [[ -d "$OLD_APP" ]]; then
      if [[ -d "$TARGET_APP" ]]; then mv "$TARGET_APP" "$STAGE/Failed.app"; fi
      mv "$OLD_APP" "$TARGET_APP"
    fi
  fi
}
trap rollback EXIT
# Stage and verify before stopping or replacing the old app. Existing user
# data, Keychain, UserDefaults, cat.config.json and TCC remain untouched. A
# custom delivery only adds a new data file to the app's pending-import inbox.
ditto "$SOURCE_APP" "$STAGE/New.app"
codesign --verify --deep --strict "$STAGE/New.app"
if (( HAS_FIRST_CAT )); then
  for directory in "$PROFILE_ROOT/Library" "$PROFILE_ROOT/Library/Application Support" "$CAT_DATA_DIR" "$CAT_INBOX"; do
    [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || fail '貓咪資料目錄在安裝期間改變；已停止匯入。'
    if [[ ! -d "$directory" ]]; then mkdir -m 700 "$directory"; fi
  done
  chmod 700 "$CAT_INBOX"
  PENDING_TEMP="$(mktemp "$CAT_INBOX/.pending.XXXXXX")"
  # The input can change after its size was checked. Copy at most the limit
  # plus one byte and recheck the snapshot before it becomes an import event.
  head -c 1048577 "$FIRST_CAT" > "$PENDING_TEMP"
  PENDING_BYTES="$(/usr/bin/stat -f %z "$PENDING_TEMP")"
  (( PENDING_BYTES > 0 && PENDING_BYTES <= 1048576 )) || fail '客製貓咪包在安裝期間改變或超出大小限制；原本的 App 尚未變動。'
  chmod 600 "$PENDING_TEMP"
  CAT_CANDIDATE="$CAT_INBOX/$(/usr/bin/uuidgen).nekocatsetup"
  [[ ! -e "$CAT_CANDIDATE" && ! -L "$CAT_CANDIDATE" ]] || fail '無法建立待匯入的貓咪檔案。'
  mv -n "$PENDING_TEMP" "$CAT_CANDIDATE"
  [[ ! -e "$PENDING_TEMP" ]] || fail '無法保存待匯入的貓咪檔案。'
  PENDING_CAT="$CAT_CANDIDATE"
  PENDING_TEMP=""
fi
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
if (( HAS_FIRST_CAT )); then print -r -- "待匯入的客製貓咪包：$PENDING_CAT"; fi
if [[ -d "$OLD_APP" ]]; then print -r -- "確認新版正常後，可以把舊版備份資料夾丟到垃圾桶：$STAGE"; fi
if (( ! TEST_MODE )); then
  if (( HAS_FIRST_CAT )); then
    # An open-document event also reaches an already-running app (the login
    # agent may have launched it). argv alone would lose that handoff. The
    # setup document never replaces an existing user's chosen appearance.
    if open -a "$TARGET_APP" "$PENDING_CAT"; then
      print -r -- '客製貓咪包已交給 App；首次使用時會自動套用，既有外觀選擇會保留。'
    else
      print -u2 -r -- 'App 已安裝，客製貓咪包已保存在待匯入目錄；下次開啟 App 時會繼續處理。'
      open "$TARGET_APP" || true
    fi
  else
    open "$TARGET_APP" || true
  fi
  if (( SHOW_DIALOGS )); then
    osascript -e 'display dialog "安裝完成！既有 API Key、快捷鍵與貓咪設定會保留。\n\n首次使用請在 App 內設定 Groq API Key，並允許麥克風與輔助使用權限。之後收到新版通知時，可自行決定是否更新。" buttons {"好"} default button "好" with title "AI 語音輸入" giving up after 120' >/dev/null || true
  fi
fi
