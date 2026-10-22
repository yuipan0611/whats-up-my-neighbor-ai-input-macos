#!/bin/zsh
set -euo pipefail
# Keep the owned tunnel alive for the browser session; never stop other SSH jobs.
# Reuse a verified office page if a tunnel from this chat is already open.
if /usr/bin/curl -fsS --max-time 2 http://127.0.0.1:18421/api/health 2>/dev/null | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("service")=="neighbor-office" and isinstance(d.get("version"),str) and d.get("worker_running") is not None' >/dev/null 2>&1; then
  /usr/bin/open http://127.0.0.1:18421
  echo '已沿用現有的貓咪辦公室連線。'
  exit 0
fi
SSH_PID=''
cleanup() {
  if [[ -n "$SSH_PID" ]]; then
    kill "$SSH_PID" 2>/dev/null || true
    wait "$SSH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM
/usr/bin/ssh -N -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L 127.0.0.1:18421:127.0.0.1:8421 neighbor-vps &
SSH_PID=$!
for attempt in {1..20}; do
  kill -0 "$SSH_PID" 2>/dev/null || { echo '連線未建立，可能已有另一個辦公室入口開著。'; exit 1; }
  if /usr/bin/curl -fsS --max-time 1 http://127.0.0.1:18421/api/health >/dev/null; then
    /usr/bin/open http://127.0.0.1:18421
    echo '貓咪辦公室已開啟。關閉這個視窗只會中斷你的連線；VPS 工作仍繼續。'
    wait "$SSH_PID"
    exit 0
  fi
  sleep 0.5
done
echo '無法確認辦公室服務，請檢查 VPS 上的服務狀態。'
exit 1
