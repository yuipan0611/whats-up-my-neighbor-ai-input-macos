#!/bin/zsh
# Reuse one already-built, signed app and deliver a separate first-use cat.
set -euo pipefail

ROOT="${0:A:h:h}"
if (( $# != 3 )); then
  print -u2 -r -- '用法：scripts/package-custom-cat.sh <AI語音輸入.app> <貓咪.nekocat> <輸出.zip>'
  exit 1
fi
SOURCE_APP="${1:A}"
CAT_PACK="${2:a}"
# Resolve existing parent symlinks before checking that output stays outside
# the signed source bundle, including when the output file is still absent.
OUTPUT="${3:A}"
[[ -d "$SOURCE_APP" && "$SOURCE_APP" == *.app ]] || { print -u2 '找不到已建置的 App。'; exit 1; }
[[ -f "$CAT_PACK" && ! -L "$CAT_PACK" && "$CAT_PACK" == *.nekocat ]] || { print -u2 '請提供一般 .nekocat 檔案。'; exit 1; }
PACK_BYTES="$(/usr/bin/stat -f %z "$CAT_PACK")"
(( PACK_BYTES > 0 && PACK_BYTES <= 1048576 )) || { print -u2 '角色包必須大於 0 bytes，且不超過 1 MiB。'; exit 1; }
[[ "$OUTPUT" == *.zip && "$OUTPUT" != "$SOURCE_APP"/* ]] || { print -u2 '輸出必須是 App 外的 .zip 路徑。'; exit 1; }
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" && ! -e "$OUTPUT.sha256" && ! -L "$OUTPUT.sha256" ]] || { print -u2 '輸出檔已存在；請指定新的檔名。'; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == tw.panh.FreeVoiceType ]] || { print -u2 'App 的 Bundle ID 不符。'; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NekoCatPackSchemaVersion' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)" == 1 ]] || { print -u2 '此 App 尚未支援角色包；請使用包含貓咪包功能的版本。'; exit 1; }
codesign --verify --deep --strict "$SOURCE_APP"

OUTPUT_DIR="${OUTPUT:h}"
mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "$OUTPUT_DIR/.neko-custom.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/NekoNode-客製貓咪"
mkdir -p "$STAGE"
ditto "$SOURCE_APP" "$STAGE/AI語音輸入.app"
codesign --verify --deep --strict "$STAGE/AI語音輸入.app"
cp "$ROOT/Packaging/安裝.command" "$STAGE/安裝.command"
cp "$ROOT/Packaging/移除.command" "$STAGE/移除.command"
cp "$ROOT/Packaging/使用說明.md" "$STAGE/使用說明.md"
mkdir -p "$STAGE/docs"
cp "$ROOT/docs/CAT-PACKS.md" "$STAGE/docs/CAT-PACKS.md"
cp "$ROOT/CAT-CONFIG.md" "$ROOT/PRIVACY.md" "$STAGE/"
cp "$CAT_PACK" "$STAGE/FirstCat.nekocatsetup"
# Keep a normal document for someone who already has a chosen cat and wants
# to apply this one explicitly. Both files contain the same data-only ZIP.
cp "$CAT_PACK" "$STAGE/我的貓.nekocat"
chmod +x "$STAGE/安裝.command" "$STAGE/移除.command"

ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$WORK/delivery.zip"
mv -n "$WORK/delivery.zip" "$OUTPUT"
[[ ! -e "$WORK/delivery.zip" ]] || { print -u2 '輸出檔已存在；未覆蓋原檔。'; exit 1; }
(cd "$OUTPUT_DIR" && shasum -a 256 -- "${OUTPUT:t}") > "$WORK/checksum"
mv -n "$WORK/checksum" "$OUTPUT.sha256"
[[ ! -e "$WORK/checksum" ]] || { print -u2 '校驗檔已存在；未覆蓋原檔。'; exit 1; }
print -r -- "客製安裝包：$OUTPUT"
print -r -- "SHA-256：$OUTPUT.sha256"
print -r -- '共用 App 與簽章未改動；角色內容由 App 在匯入時驗證。'
