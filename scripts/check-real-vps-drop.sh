#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"

ALIAS="${VPS_ALIAS:-neighbor-vps}"
HOLD="${HOLD_SECONDS:-600}"
WORK="$ROOT/build/real-vps-drop"

rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

REMOTE_LIST_SSHD='self=$(ps -o ppid= -p $$ | tr -d " "); ps -u "$(id -u)" -o pid=,comm= | awk -v s="$self" '\''$2 ~ /^sshd/ && $1 != s {print $1}'\'' | sort'

DROP_CHECK_PID=""
TUNNEL_PID=""
cleanup_done=0

cleanup() {
    if [[ "$cleanup_done" -eq 1 ]]; then
        return
    fi
    cleanup_done=1
    if [[ -n "$TUNNEL_PID" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "kill -CONT $TUNNEL_PID 2>/dev/null || true; kill $TUNNEL_PID 2>/dev/null || true" 2>/dev/null || true
        sleep 1
    fi
    if [[ -n "$DROP_CHECK_PID" ]] && kill -0 "$DROP_CHECK_PID" 2>/dev/null; then
        kill "$DROP_CHECK_PID" 2>/dev/null || true
        wait "$DROP_CHECK_PID" 2>/dev/null || true
    fi
    pkill -f -- "-L 127.0.0.1:15901:127.0.0.1:5901 -- $ALIAS" 2>/dev/null || true
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "$REMOTE_LIST_SSHD" > "$WORK/sshd-final.txt" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" true; then
    echo "錯誤: 無法用金鑰登入 $ALIAS" >&2
    exit 3
fi

REMOTE_SS="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" 'ss -ltn')"
REMOTE_5901="$(echo "$REMOTE_SS" | grep ':5901' || true)"
if [[ -z "$REMOTE_5901" ]]; then
    echo "錯誤: $ALIAS 上沒有 5901 的監聽" >&2
    exit 3
fi
if echo "$REMOTE_5901" | grep -qvE '127\.0\.0\.1:5901|\[::1\]:5901'; then
    echo "錯誤: $ALIAS 的 5901 監聽在非 loopback 位址" >&2
    exit 3
fi

if lsof -nP -iTCP:15901 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "錯誤: 本機 127.0.0.1:15901 已經被其他程序佔用" >&2
    exit 3
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "$REMOTE_LIST_SSHD" > "$WORK/sshd-before.txt"

swiftc -swift-version 5 \
    "$ROOT/Sources/NeighborAgentCore/SSHTunnel.swift" \
    "$ROOT/Sources/NeighborAgentCore/RemoteDesktopHandoff.swift" \
    "$ROOT/Tests/RemoteDesktopVPSDropCheck.swift" \
    -o "$WORK/drop-check"

"$WORK/drop-check" --alias "$ALIAS" --hold-seconds "$HOLD" --ready-file "$WORK/ready" > "$WORK/drop-check.stdout" 2>&1 &
DROP_CHECK_PID=$!

VIEWER_OPENED_FOUND=0
for (( i=0; i<40; i++ )); do
    if grep -q "state: viewerOpened" "$WORK/drop-check.stdout" 2>/dev/null; then
        VIEWER_OPENED_FOUND=1
        break
    fi
    sleep 1
done

if [[ "$VIEWER_OPENED_FOUND" -ne 1 ]]; then
    echo "錯誤: 等待 viewerOpened 逾時" >&2
    exit 4
fi

sleep 2
ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "$REMOTE_LIST_SSHD" > "$WORK/sshd-after.txt"

DIFF_PIDS="$(comm -13 "$WORK/sshd-before.txt" "$WORK/sshd-after.txt" | grep -v '^[[:space:]]*$' || true)"
PID_COUNT="$(echo "$DIFF_PIDS" | grep -c . || true)"
if [[ "$PID_COUNT" -ne 1 ]]; then
    echo "錯誤: 新增的 sshd 程序數量不為 1 (找到 $PID_COUNT 個):" >&2
    echo "$DIFF_PIDS" >&2
    exit 6
fi
TUNNEL_PID="$(echo "$DIFF_PIDS" | tr -d ' ')"
if [[ ! "$TUNNEL_PID" =~ '^[0-9]+$' ]]; then
    echo "錯誤: 取得的 PID 不是數字: $TUNNEL_PID" >&2
    TUNNEL_PID=""
    exit 6
fi

WAIT_READY_LIMIT=$(( HOLD + 60 ))
READY_FOUND=0
for (( i=0; i<WAIT_READY_LIMIT; i++ )); do
    if [[ -f "$WORK/ready" ]]; then
        READY_FOUND=1
        break
    fi
    if ! kill -0 "$DROP_CHECK_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [[ "$READY_FOUND" -ne 1 ]]; then
    echo "錯誤: 等待 ready 檔逾時或 drop-check 提前結束" >&2
    exit 4
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "kill -STOP $TUNNEL_PID"
echo "froze remote sshd $TUNNEL_PID"

DROP_CHECK_EXIT=""
for (( i=0; i<180; i++ )); do
    if ! kill -0 "$DROP_CHECK_PID" 2>/dev/null; then
        wait "$DROP_CHECK_PID" && DROP_CHECK_EXIT=0 || DROP_CHECK_EXIT=$?
        break
    fi
    sleep 1
done

if [[ -z "$DROP_CHECK_EXIT" ]]; then
    kill "$DROP_CHECK_PID" 2>/dev/null || true
    wait "$DROP_CHECK_PID" 2>/dev/null || true
    DROP_CHECK_EXIT=124
fi

cleanup

ALIVE_TOTAL="$(grep -c "^alive " "$WORK/drop-check.stdout" 2>/dev/null || true)"
ALIVE_FAILED="$(grep "^alive " "$WORK/drop-check.stdout" 2>/dev/null | grep -vc "state=viewerOpened listener=true probe=true" || true)"
DROP_LINE="$(grep "^DROP_DETECTED" "$WORK/drop-check.stdout" 2>/dev/null || true)"
RELEASE_LINE="$(grep "^tunnel released:" "$WORK/drop-check.stdout" 2>/dev/null || true)"

C_EQUALS_A="false"
if cmp -s "$WORK/sshd-before.txt" "$WORK/sshd-final.txt"; then
    C_EQUALS_A="true"
fi

echo "========================================"
echo "真實 VPS 長時間連線與網路中斷檢查摘要"
echo "========================================"
echo "alive 行數: $ALIVE_TOTAL, 失敗數: $ALIVE_FAILED"
echo "中斷偵測: ${DROP_LINE:-無}"
echo "通道釋放: ${RELEASE_LINE:-無}"
echo "drop-check 結束碼: $DROP_CHECK_EXIT"
echo "遠端無殘留程序 (C == A): $C_EQUALS_A"
echo "----------------------------------------"
echo "drop-check.stdout 最後 15 行:"
tail -n 15 "$WORK/drop-check.stdout" 2>/dev/null || true
echo "========================================"

if [[ "$DROP_CHECK_EXIT" -eq 0 && "$C_EQUALS_A" == "true" ]]; then
    exit 0
else
    exit 4
fi
