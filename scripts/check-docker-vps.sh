#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"

CHECK_WAIT="${CHECK_WAIT:-90}"
IMAGE="${IMAGE:-neighbor-vps-test:local}"
NAME="${NAME:-neighbor-vps-test}"
WORK="$ROOT/build/docker-vps"
KEEP_IMAGE="${KEEP_IMAGE:-0}"

if ! docker version >/dev/null 2>&1; then
    echo "錯誤: 無法連線至 Docker daemon，請確認 Docker Desktop 已啟動" >&2
    exit 3
fi

for port in 22923 15901; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "錯誤: 127.0.0.1:$port 已經被其他程序佔用：" >&2
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2
        exit 3
    fi
done

WAS_SCREEN_SHARING_RUNNING=0
if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
    WAS_SCREEN_SHARING_RUNNING=1
fi

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    if [[ "$KEEP_IMAGE" -ne 1 ]]; then
        docker rmi "$IMAGE" debian:bookworm-slim >/dev/null 2>&1 || true
    fi
    if [[ "$WAS_SCREEN_SHARING_RUNNING" -eq 0 ]]; then
        if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
            osascript -e 'quit app "Screen Sharing"' 2>/dev/null || true
        fi
    fi
    rm -f "$WORK/host_key" "$WORK/client_key" "$WORK/vnc-password"
    rm -rf "$WORK/mount"
}
trap cleanup EXIT INT TERM

rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_key"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/client_key"

if [[ -n "${VNC_TEST_PASSWORD:-}" ]]; then
    print -rn -- "$VNC_TEST_PASSWORD" > "$WORK/vnc-password"
else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8 > "$WORK/vnc-password"
fi
chmod 600 "$WORK/vnc-password"

mkdir -p "$WORK/mount"
cp "$WORK/host_key" "$WORK/mount/ssh_host_ed25519_key"
chmod 600 "$WORK/mount/ssh_host_ed25519_key"
cp "$WORK/host_key.pub" "$WORK/mount/ssh_host_ed25519_key.pub"
chmod 644 "$WORK/mount/ssh_host_ed25519_key.pub"
cp "$WORK/client_key.pub" "$WORK/mount/authorized_keys"
chmod 644 "$WORK/mount/authorized_keys"
cp "$WORK/vnc-password" "$WORK/mount/vnc-password"
chmod 644 "$WORK/mount/vnc-password"
chmod 755 "$WORK/mount"

HOST_KEY_PARTS="$(awk '{print $1, $2}' "$WORK/host_key.pub")"
echo "[127.0.0.1]:22923 $HOST_KEY_PARTS" > "$WORK/known_hosts"

cat <<EOF > "$WORK/ssh_config"
Host 127.0.0.1
  Port 22923
  User neighbor
  IdentityFile "$WORK/client_key"
  IdentitiesOnly yes
  UserKnownHostsFile "$WORK/known_hosts"
  GlobalKnownHostsFile /dev/null
EOF

docker build -t "$IMAGE" "$ROOT/scripts/docker-vps"
docker run -d --name "$NAME" -p 127.0.0.1:22923:22 -v "$WORK/mount:/run/neighbor:ro" "$IMAGE"

PORT_READY=0
for i in {1..300}; do
    if lsof -nP -iTCP:22923 -sTCP:LISTEN >/dev/null 2>&1; then
        PORT_READY=1
        break
    fi
    sleep 0.1
done

if [[ "$PORT_READY" -ne 1 ]]; then
    echo "錯誤: 容器 sshd 未能在 30 秒內於 127.0.0.1:22923 啟動監聽" >&2
    exit 4
fi

VNC_READY=0
for i in {1..600}; do
    if docker exec "$NAME" ss -ltn 2>/dev/null | grep -q "127.0.0.1:5901"; then
        VNC_READY=1
        break
    fi
    sleep 0.1
done

if [[ "$VNC_READY" -ne 1 ]]; then
    echo "錯誤: 容器內 vncserver 未能在 60 秒內於 127.0.0.1:5901 啟動監聽" >&2
    exit 4
fi

SS_5901_LINES="$(docker exec "$NAME" ss -ltn 2>/dev/null | grep "5901" || true)"
echo "容器內 5901 監聽狀態:"
echo "$SS_5901_LINES"

setup_self_check="fail"
if echo "$SS_5901_LINES" | grep -q "127.0.0.1:5901" && ! echo "$SS_5901_LINES" | grep -qE "0\.0\.0\.0:5901|\*:5901"; then
    setup_self_check="pass"
fi

echo "螢幕共享跳出密碼框時，請輸入 $WORK/vnc-password 檔案中的 8 字元密碼（可在另一個終端機執行 cat 查看），然後按登入。"

swiftc -swift-version 5 \
    "$ROOT/Sources/NeighborAgentCore/SSHTunnel.swift" \
    "$ROOT/Sources/NeighborAgentCore/RemoteDesktopHandoff.swift" \
    "$ROOT/Tests/RemoteDesktopVPSLiveCheck.swift" \
    -o "$WORK/RemoteDesktopVPSLiveCheck"

LIVE_CHECK_EXIT=0
"$WORK/RemoteDesktopVPSLiveCheck" --ssh-config "$WORK/ssh_config" --hold "$CHECK_WAIT" > "$WORK/live-check.stdout" 2>&1 || LIVE_CHECK_EXIT=$?

CONTROLLER_FINAL_STATE="$(grep "final state:" "$WORK/live-check.stdout" 2>/dev/null | tail -n 1 | sed 's/.*final state: //' || echo "unknown")"
TUNNEL_CLOSED="$(grep "tunnel closed after stop:" "$WORK/live-check.stdout" 2>/dev/null | tail -n 1 | sed 's/.*tunnel closed after stop: //' || echo "unknown")"

DOCKER_LOGS="$(docker logs "$NAME" 2>&1 || true)"
docker exec "$NAME" sh -c 'cat /home/neighbor/.vnc/*.log' > "$WORK/tigervnc.log" 2>&1 || true
VNC_ACCEPTED=$(grep -c "Connections: accepted" "$WORK/tigervnc.log" 2>/dev/null || true)
VNC_AUTH_FAILED=$(grep -c "AuthFailed\|Authentication failure" "$WORK/tigervnc.log" 2>/dev/null || true)
VNC_PIXEL=$(grep -c "Client pixel format\|Using pixel format\|SConnection: Client needs protocol" "$WORK/tigervnc.log" 2>/dev/null || true)
HAS_ACCEPTED_PUBKEY=0
if echo "$DOCKER_LOGS" | grep -q "Accepted publickey"; then
    HAS_ACCEPTED_PUBKEY=1
fi

echo "========================================"
echo "Docker VPS 端到端檢查摘要"
echo "========================================"
echo "TigerVNC 接受的連線數: ${VNC_ACCEPTED:-0}"
echo "TigerVNC 認證失敗次數: ${VNC_AUTH_FAILED:-0}"
echo "TigerVNC 進入工作階段的紀錄行數: ${VNC_PIXEL:-0}"
echo "TigerVNC log: $WORK/tigervnc.log"
echo "Live Check 結束碼: $LIVE_CHECK_EXIT"
echo "控制器最終狀態: $CONTROLLER_FINAL_STATE"
echo "Stop 後 15901 釋放: $TUNNEL_CLOSED"
echo "SETUP.md 自我檢查: $setup_self_check"
if [[ "$HAS_ACCEPTED_PUBKEY" -eq 1 ]]; then
    echo "sshd 接受金鑰: 是"
else
    echo "sshd 接受金鑰: 否"
fi
echo "----------------------------------------"
echo "docker logs 最後 20 行:"
echo "$DOCKER_LOGS" | tail -n 20
echo "========================================"

if [[ "$LIVE_CHECK_EXIT" -eq 0 && "$setup_self_check" == "pass" && "$HAS_ACCEPTED_PUBKEY" -eq 1 ]]; then
    exit 0
else
    exit 4
fi
