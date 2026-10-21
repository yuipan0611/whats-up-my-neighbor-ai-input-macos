#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"

CHECK_WAIT="${CHECK_WAIT:-30}"
BUILD_DIR="$ROOT/build/loopback-check"
mkdir -p "$BUILD_DIR"
LOG_FILE="$BUILD_DIR/server.log"
LIVE_CHECK_BIN="$BUILD_DIR/RemoteDesktopLiveCheck"
LIVE_CHECK_OUT="$BUILD_DIR/live-check.stdout"

if lsof -nP -iTCP:5901 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "錯誤: 127.0.0.1:5901 已經被其他程序佔用：" >&2
    lsof -nP -iTCP:5901 -sTCP:LISTEN >&2
    exit 3
fi

WAS_SCREEN_SHARING_RUNNING=0
if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
    WAS_SCREEN_SHARING_RUNNING=1
fi

SERVER_PID=""
cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [[ "$WAS_SCREEN_SHARING_RUNNING" -eq 0 ]]; then
        if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
            osascript -e 'quit app "Screen Sharing"' 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

rm -f "$LOG_FILE"
python3 "$ROOT/scripts/fake-rfb-server.py" --port 5901 --log "$LOG_FILE" --timeout $(( CHECK_WAIT + 30 )) --security "${CHECK_SECURITY:-vncauth}" &
SERVER_PID=$!

SERVER_READY=0
for i in {1..50}; do
    if lsof -nP -iTCP:5901 -sTCP:LISTEN >/dev/null 2>&1; then
        SERVER_READY=1
        break
    fi
    sleep 0.1
done

if [[ "$SERVER_READY" -ne 1 ]]; then
    echo "錯誤: fake-rfb-server.py 未能在 5 秒內於 127.0.0.1:5901 啟動監聽" >&2
    exit 1
fi

swiftc -swift-version 5 \
    "$ROOT/Sources/NeighborAgentCore/SSHTunnel.swift" \
    "$ROOT/Sources/NeighborAgentCore/RemoteDesktopHandoff.swift" \
    "$ROOT/Tests/RemoteDesktopLiveCheck.swift" \
    -o "$LIVE_CHECK_BIN"

LIVE_CHECK_EXIT=0
"$LIVE_CHECK_BIN" > "$LIVE_CHECK_OUT" 2>&1 || LIVE_CHECK_EXIT=$?

GOT_FRAMEBUFFER_REQUEST=0
for i in {1..$(( CHECK_WAIT * 10 ))}; do
    if [[ -f "$LOG_FILE" ]] && grep -q "FramebufferUpdateRequest" "$LOG_FILE"; then
        GOT_FRAMEBUFFER_REQUEST=1
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if [[ "$GOT_FRAMEBUFFER_REQUEST" -eq 1 ]]; then
    sleep 0.5
fi

CONTROLLER_FINAL_STATE=$(grep "final state:" "$LIVE_CHECK_OUT" 2>/dev/null | tail -n 1 | sed 's/.*final state: //' || echo "unknown")
CLIENT_VERSION=$(grep "client version:" "$LOG_FILE" 2>/dev/null | tail -n 1 | sed 's/.*client version: //' || echo "none")
SECURITY_TYPE=$(grep -E "client selected security type:|security type chosen by server:" "$LOG_FILE" 2>/dev/null | tail -n 1 | sed -E 's/.*\] //' || true)
FRAMES_SENT=$(grep -c "frame .* sent" "$LOG_FILE" 2>/dev/null || true)

echo "========================================"
echo "螢幕共享 Loopback 檢查摘要"
echo "========================================"
echo "控制器最終狀態: $CONTROLLER_FINAL_STATE"
echo "客戶端版本: $CLIENT_VERSION"
echo "安全類型協商: ${SECURITY_TYPE:-（未到這一步）}"
if [[ "$GOT_FRAMEBUFFER_REQUEST" -eq 1 ]]; then
    echo "收到 FramebufferUpdateRequest: 是"
else
    echo "收到 FramebufferUpdateRequest: 否"
    if grep -q "security type chosen by server\|client selected security type" "$LOG_FILE" 2>/dev/null && ! grep -q "ClientInit" "$LOG_FILE" 2>/dev/null; then
        echo "停在登入步驟：螢幕共享會先跳出密碼對話框，假伺服器不驗證密碼。以 CHECK_WAIT=90 重跑，並在對話框輸入任意字元。"
    fi
fi
echo "送出畫面張數: $FRAMES_SENT"
echo "----------------------------------------"
echo "最後 20 行 server.log:"
if [[ -f "$LOG_FILE" ]]; then
    tail -n 20 "$LOG_FILE"
else
    echo "(log 檔案不存在)"
fi
echo "========================================"

if [[ "$GOT_FRAMEBUFFER_REQUEST" -eq 1 ]]; then
    exit 0
elif grep -q "client version:" "$LOG_FILE" 2>/dev/null; then
    exit 5
else
    exit 4
fi
