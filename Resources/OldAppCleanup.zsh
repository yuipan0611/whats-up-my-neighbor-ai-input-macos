#!/bin/zsh
# Shared by the installer and the installed App after a Sparkle update.
prune_completed_app_backups() {
  local install_dir="$1" excluded="${2:-}" label="tw.panh.FreeVoiceType"
  local backup modified users query_status failed=0
  local -a entries
  for backup in "$install_dir"/.neighbor-update.*(N); do
    [[ "$backup" != "$excluded" && -d "$backup" && ! -L "$backup" ]] || continue
    entries=("$backup"/*(DN))
    if (( ${#entries} != 1 )) || [[ "${entries[1]}" != "$backup/Previous.app" || -L "$backup/Previous.app" || ! -d "$backup/Previous.app" ]]; then
      print -r -- "略過未確認或進行中的暫存：$backup"
      continue
    fi
    if ! modified="$(stat -f %m "$backup")"; then
      print -u2 -r -- "無法檢查備份，已保留：$backup"
      continue
    fi
    if (( $(date +%s) - modified < 86400 )); then
      print -r -- "略過近期暫存：$backup"
      continue
    fi
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$backup/Previous.app/Contents/Info.plist" 2>/dev/null || true)" != "$label" ]] || ! codesign --verify --deep --strict "$backup/Previous.app" 2>/dev/null; then
      print -r -- "略過身分無法確認的備份：$backup"
      continue
    fi
    # lsof on macOS can emit matching PIDs and still exit 1 (partial results).
    # Only an empty result with the normal no-match status permits deletion.
    if users="$(/usr/sbin/lsof -t +D "$backup" 2>&1)"; then query_status=0; else query_status=$?; fi
    if [[ -n "$users" ]] || (( query_status != 1 )); then
      print -r -- "略過正在使用或無法確認使用狀態的備份：$backup"
      continue
    fi
    if rm -rf "$backup/Previous.app" && rmdir "$backup"; then
      print -r -- "已清除舊版備份：$backup"
    else
      print -u2 -r -- "舊版備份清理失敗，殘留位置：$backup"
      failed=1
    fi
  done
  return "$failed"
}

cleanup_after_app_launch() {
  set -euo pipefail
  [[ $# == 2 && "$1" == --app-launch ]] || return 64
  local app="$2" label="tw.panh.FreeVoiceType"
  local profile="${HOME:A}"
  # Never run cleanup from a download, preview, worktree, or symlinked bundle.
  [[ "$app" == "${app:A}" && -d "$app" && ! -L "$app" ]] || return 65
  case "$app" in
    "$profile/Applications/AI語音輸入.app"|"$profile/Library/Application Support/AI語音輸入/AI語音輸入.app"|/Applications/AI語音輸入.app) ;;
    *) return 65 ;;
  esac
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" == "$label" ]] || return 65
  /usr/bin/codesign --verify --deep --strict "$app" || return 65
  NEIGHBOR_CLEANUP_LOCK="${app:h}/.neighbor-install.lock"
  mkdir "$NEIGHBOR_CLEANUP_LOCK" 2>/dev/null || return 75
  # Share the installer's lock: the new App can start before installation commits.
  trap 'rm -f "$NEIGHBOR_CLEANUP_LOCK/pid"; rmdir "$NEIGHBOR_CLEANUP_LOCK"' EXIT
  print -r -- "$$" > "$NEIGHBOR_CLEANUP_LOCK/pid"
  prune_completed_app_backups "${app:h}"
}

if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  cleanup_after_app_launch "$@"
fi
