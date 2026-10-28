#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"

CHECK_WAIT="${CHECK_WAIT:-20}"

for port in 22922 15901 5901; do
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

WORK="$ROOT/build/vps-loopback-check"
rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

SERVER_PID=""
SSHD_PID=""
cleanup() {
    if [[ -f "$WORK/sshd.pid" ]]; then
        local pid
        pid="$(cat "$WORK/sshd.pid" 2>/dev/null || true)"
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
    if [[ -n "${SSHD_PID:-}" ]] && kill -0 "$SSHD_PID" 2>/dev/null; then
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
    fi
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [[ "$WAS_SCREEN_SHARING_RUNNING" -eq 0 ]]; then
        if pgrep -x "Screen Sharing" >/dev/null 2>&1; then
            osascript -e 'quit app "Screen Sharing"' 2>/dev/null || true
        fi
    fi
    rm -f "$WORK/host_key" "$WORK/client_key"
}
trap cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_key"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/client_key"
cp "$WORK/client_key.pub" "$WORK/authorized_keys"
chmod 600 "$WORK/authorized_keys"

cat <<EOF > "$WORK/sshd_config"
ListenAddress 127.0.0.1:22922
HostKey "$WORK/host_key"
PidFile "$WORK/sshd.pid"
AuthorizedKeysFile "$WORK/authorized_keys"
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowTcpForwarding local
PermitOpen 127.0.0.1:5901
AllowAgentForwarding no
X11Forwarding no
PermitTTY no
StrictModes no
EOF

HOST_KEY_PARTS="$(awk '{print $1, $2}' "$WORK/host_key.pub")"
echo "[127.0.0.1]:22922 $HOST_KEY_PARTS" > "$WORK/known_hosts"

CURRENT_USER="$(whoami)"
cat <<EOF > "$WORK/ssh_config"
Host 127.0.0.1
  Port 22922
  User $CURRENT_USER
  IdentityFile "$WORK/client_key"
  IdentitiesOnly yes
  UserKnownHostsFile "$WORK/known_hosts"
  GlobalKnownHostsFile /dev/null
EOF

/usr/sbin/sshd -t -f "$WORK/sshd_config"

/usr/sbin/sshd -D -e -f "$WORK/sshd_config" > "$WORK/sshd.log" 2>&1 &
SSHD_PID=$!

SSHD_READY=0
for i in {1..50}; do
    if lsof -nP -iTCP:22922 -sTCP:LISTEN >/dev/null 2>&1; then
        SSHD_READY=1
        break
    fi
    sleep 0.1
done

if [[ "$SSHD_READY" -ne 1 ]]; then
    echo "錯誤: sshd 未能在 5 秒內於 127.0.0.1:22922 啟動監聽" >&2
    exit 1
fi

python3 -I "$ROOT/scripts/fake-rfb-server.py" --port 5901 --log "$WORK/server.log" --timeout $(( CHECK_WAIT + 60 )) &
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
    "$ROOT/Tests/RemoteDesktopVPSLiveCheck.swift" \
    -o "$WORK/RemoteDesktopVPSLiveCheck"

LIVE_CHECK_EXIT=0
"$WORK/RemoteDesktopVPSLiveCheck" --ssh-config "$WORK/ssh_config" --hold "$CHECK_WAIT" > "$WORK/live-check.stdout" 2>&1 || LIVE_CHECK_EXIT=$?

CONTROLLER_FINAL_STATE="$(grep "final state:" "$WORK/live-check.stdout" 2>/dev/null | tail -n 1 | sed 's/.*final state: //' || echo "unknown")"
TUNNEL_CLOSED="$(grep "tunnel closed after stop:" "$WORK/live-check.stdout" 2>/dev/null | tail -n 1 | sed 's/.*tunnel closed after stop: //' || echo "unknown")"

HAS_ACCEPTED_PUBKEY=0
if grep -q "Accepted publickey" "$WORK/sshd.log" 2>/dev/null; then
    HAS_ACCEPTED_PUBKEY=1
fi

HAS_PROBE_DISCONNECTED=0
if grep -q "probe connection disconnected" "$WORK/server.log" 2>/dev/null; then
    HAS_PROBE_DISCONNECTED=1
fi

CLIENT_VERSION_LINE="$(grep "client version:" "$WORK/server.log" 2>/dev/null | tail -n 1 || true)"
HAS_CLIENT_VERSION=0
if [[ -n "$CLIENT_VERSION_LINE" ]]; then
    HAS_CLIENT_VERSION=1
fi

echo "========================================"
echo "VPS 路徑 Loopback 檢查摘要"
echo "========================================"
echo "Live Check 結束碼: $LIVE_CHECK_EXIT"
echo "控制器最終狀態: $CONTROLLER_FINAL_STATE"
echo "Stop 後 15901 釋放: $TUNNEL_CLOSED"
if [[ "$HAS_ACCEPTED_PUBKEY" -eq 1 ]]; then
    echo "sshd 接受金鑰: 是"
else
    echo "sshd 接受金鑰: 否"
fi
if [[ "$HAS_PROBE_DISCONNECTED" -eq 1 ]]; then
    echo "探測連線已到達: 是"
else
    echo "探測連線已到達: 否"
fi
if [[ "$HAS_CLIENT_VERSION" -eq 1 ]]; then
    echo "螢幕共享連線: $CLIENT_VERSION_LINE"
else
    echo "螢幕共享連線: 否"
fi
echo "----------------------------------------"
echo "sshd.log 最後 15 行:"
tail -n 15 "$WORK/sshd.log" 2>/dev/null || true
echo "----------------------------------------"
echo "server.log 最後 15 行:"
tail -n 15 "$WORK/server.log" 2>/dev/null || true
echo "========================================"

if [[ "$LIVE_CHECK_EXIT" -eq 0 && "$HAS_ACCEPTED_PUBKEY" -eq 1 && "$HAS_CLIENT_VERSION" -eq 1 ]]; then
    exit 0
else
    exit 4
fi
