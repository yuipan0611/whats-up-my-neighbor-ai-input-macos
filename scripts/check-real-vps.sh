#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"

CHECK_WAIT="${CHECK_WAIT:-20}"
ALIAS="${VPS_ALIAS:-neighbor-vps}"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
REMOTE_LOG='$(ls -1 ~/.vnc/*:1.log | head -n 1)'

if lsof -nP -iTCP:15901 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "錯誤: 127.0.0.1:15901 已經被其他程序佔用：" >&2
    lsof -nP -iTCP:15901 -sTCP:LISTEN >&2
    exit 3
fi

if ! ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" true; then
    echo "錯誤: 無法用金鑰登入 $ALIAS，先確認 ~/.ssh/config 與 known_hosts" >&2
    exit 3
fi

if ! ssh -F "$SSH_CONFIG" -o BatchMode=yes "$ALIAS" "ss -ltn | grep -q '127.0.0.1:5901'"; then
    echo "錯誤: $ALIAS 上沒有 127.0.0.1:5901 的監聽，先以 neighbor 執行 vncserver :1 -localhost yes -SecurityTypes VncAuth" >&2
    exit 3
fi

if ssh -F "$SSH_CONFIG" -o BatchMode=yes "$ALIAS" "ss -ltn | grep -Eq '(0\.0\.0\.0|\*|\[::\]):5901'"; then
    echo "錯誤: $ALIAS 的 5901 監聽在非 loopback 位址，停止檢查" >&2
    exit 3
fi

WAS_SCREEN_SHARING_RUNNING=0
if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
    WAS_SCREEN_SHARING_RUNNING=1
fi

WORK="$ROOT/build/real-vps-check"
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

cleanup() {
    if [[ "$WAS_SCREEN_SHARING_RUNNING" -eq 0 ]]; then
        if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
            osascript -e 'quit app "Screen Sharing"' 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

LOG_LINES_BEFORE="$(ssh -F "$SSH_CONFIG" -o BatchMode=yes "$ALIAS" "wc -l < $REMOTE_LOG" | tr -d ' ')"

swiftc -swift-version 5 \
    "$ROOT/Sources/NeighborAgentCore/SSHTunnel.swift" \
    "$ROOT/Sources/NeighborAgentCore/RemoteDesktopHandoff.swift" \
    "$ROOT/Tests/RemoteDesktopVPSLiveCheck.swift" \
    -o "$WORK/RemoteDesktopVPSLiveCheck"

echo "螢幕共享跳出密碼框時，請輸入 VPS 的 VNC 密碼並按登入；接著確認看得到 XFCE 桌面、滑鼠與鍵盤可用。通道會保持 $CHECK_WAIT 秒。"

LIVE_CHECK_EXIT=0
"$WORK/RemoteDesktopVPSLiveCheck" --ssh-config "$SSH_CONFIG" --alias "$ALIAS" --hold "$CHECK_WAIT" > "$WORK/live-check.stdout" 2>&1 || LIVE_CHECK_EXIT=$?

ssh -F "$SSH_CONFIG" -o BatchMode=yes "$ALIAS" "tail -n +$(( LOG_LINES_BEFORE + 1 )) $REMOTE_LOG" > "$WORK/vnc-server.log" 2>&1 || true

CONTROLLER_FINAL_STATE="$(grep "final state:" "$WORK/live-check.stdout" 2>/dev/null | tail -n 1 | sed 's/.*final state: //' || echo "unknown")"
TUNNEL_CLOSED="$(grep "tunnel closed after stop:" "$WORK/live-check.stdout" 2>/dev/null | tail -n 1 | sed 's/.*tunnel closed after stop: //' || echo "unknown")"
VIEWER_OPENED=0
if grep -q "viewer opened" "$WORK/live-check.stdout" 2>/dev/null; then
    VIEWER_OPENED=1
fi

echo "========================================"
echo "真實 VPS 接手控制檢查摘要（$ALIAS）"
echo "========================================"
echo "Live Check 結束碼: $LIVE_CHECK_EXIT"
echo "控制器最終狀態: $CONTROLLER_FINAL_STATE"
echo "檢視器已開啟: $VIEWER_OPENED"
echo "Stop 後 15901 釋放: $TUNNEL_CLOSED"
echo "VNC 伺服器 log 新增 $(wc -l < "$WORK/vnc-server.log" | tr -d ' ') 行；含 auth 失敗字樣的行數: $(grep -ciE 'auth.*(fail|denied)|authentication failed' "$WORK/vnc-server.log" || true)"
echo "----------------------------------------"
echo "live-check 輸出:"
cat "$WORK/live-check.stdout"
echo "----------------------------------------"
echo "VNC 伺服器 log 新增內容（最後 30 行）:"
tail -n 30 "$WORK/vnc-server.log"
echo "========================================"

if [[ "$LIVE_CHECK_EXIT" -eq 0 && "$VIEWER_OPENED" -eq 1 ]]; then
    exit 0
else
    exit 4
fi
