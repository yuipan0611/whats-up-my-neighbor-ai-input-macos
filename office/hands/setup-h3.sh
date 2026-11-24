#!/usr/bin/env bash
# agent-hands H3: root setup for the cat's hands to start working (PRD 7, 9.1; ADR-001 section 7).
#
#   bash setup-h3.sh <sha256 of the staged worker.py>
#
# Installs root-owned tools the cat can run but not change: Node.js, the pinned official Codex
# CLI, the pinned browser tool server, the worker, and two system services that run as neko-hands
# inside its memory ceiling: its Chrome (DevTools on 127.0.0.1:9222) and the worker. Safe to rerun.
set -euo pipefail
umask 022

HANDS=neko-hands
OPT=/opt/neko-hands
STAGE=/home/neighbor/neko-h3
CODEX_VERSION=0.163.0
MCP_VERSION=1.12.0
CODEX_ASSETS=(
  'codex-x86_64-unknown-linux-musl beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4'
  'codex-code-mode-host-x86_64-unknown-linux-musl 314263128ba6592e7e807c265deeaf928a692b72dcbfeb5e0b20c9423b703529'
  'bwrap-x86_64-unknown-linux-musl bcc196b1d25dc2c2b912dcedf780b562deb0552f3c50648761ced145c3466a23'
)

say() { printf '\n== %s\n' "$*"; }
ok()  { printf '   ✓ %s\n' "$*"; }
die() { printf '   ✗ %s\n' "$*" >&2; exit 1; }

say '0. 先檢查'
[ "$(id -u)" = 0 ] || { echo '請用 root 執行。' >&2; exit 1; }
[ $# = 1 ] || die '用法：bash setup-h3.sh <worker.py 的 sha256>'
id "$HANDS" >/dev/null 2>&1 || die "找不到 $HANDS，請先跑 H1。"
[ -S /srv/neko-office/worker.sock ] || die '辦公室的 worker 入口不存在（需要 0.5.x 並開 --worker-socket）。'
HANDS_UID=$(id -u "$HANDS")
[ "$(sha256sum "$STAGE/worker.py" | cut -d' ' -f1)" = "$1" ] || die 'worker.py 的指紋不符，停止。'
ok "neko-hands（uid $HANDS_UID）、辦公室的 worker 入口、worker.py 指紋都對"

say '1. Node.js（瀏覽器工具需要）'
if ! command -v node >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs npm >/dev/null
fi
ok "node $(node --version)，npm $(npm --version)"

say '2. 官方 Codex CLI（固定版本、核對 SHA-256，root 擁有）'
install -d -o root -g root -m 0755 "$OPT" "$OPT/codex"
for asset in "${CODEX_ASSETS[@]}"; do
  name=${asset%% *}; expected=${asset##* }
  archive="$OPT/codex/$name-$CODEX_VERSION.tar.gz"
  if [ ! -f "$archive" ] || [ "$(sha256sum "$archive" | cut -d' ' -f1)" != "$expected" ]; then
    curl -fLsS --retry 3 "https://github.com/openai/codex/releases/download/rust-v$CODEX_VERSION/$name.tar.gz" -o "$archive"
  fi
  [ "$(sha256sum "$archive" | cut -d' ' -f1)" = "$expected" ] || die "$name 的官方指紋不符，停止。"
  [ "$(tar -tzf "$archive")" = "$name" ] || die "$name 的壓縮檔內容不符預期，停止。"
  tar -xzf "$archive" -C "$OPT/codex" "$name"
  chown root:root "$OPT/codex/$name"; chmod 0755 "$OPT/codex/$name"
done
cp -f "$OPT/codex/codex-code-mode-host-x86_64-unknown-linux-musl" "$OPT/codex/codex-code-mode-host"
cp -f "$OPT/codex/bwrap-x86_64-unknown-linux-musl" "$OPT/codex/bwrap"
chmod 0755 "$OPT/codex/codex-code-mode-host" "$OPT/codex/bwrap"
ok "$("$OPT/codex/codex-x86_64-unknown-linux-musl" --version)（三個官方檔案的 SHA-256 都對）"

say '3. 瀏覽器工具（chrome-devtools-mcp，固定版本、不執行安裝腳本）'
install -d -o root -g root -m 0755 "$OPT/mcp"
if [ "$(node -p "try{require('$OPT/mcp/node_modules/chrome-devtools-mcp/package.json').version}catch(e){''}")" != "$MCP_VERSION" ]; then
  npm install --prefix "$OPT/mcp" --ignore-scripts --no-audit --no-fund --save-exact "chrome-devtools-mcp@$MCP_VERSION" >/dev/null
fi
chown -R root:root "$OPT/mcp"; chmod -R go-w "$OPT/mcp"
[ "$(node -p "require('$OPT/mcp/node_modules/chrome-devtools-mcp/package.json').version")" = "$MCP_VERSION" ] || die '瀏覽器工具版本不對。'
ok "chrome-devtools-mcp $MCP_VERSION（$OPT/mcp，root 擁有）"

say '4. worker（root 擁有，貓咪改不了）'
install -o root -g root -m 0755 "$STAGE/worker.py" "$OPT/worker.py"
ok "$OPT/worker.py sha256 ${1:0:16}…"

say '5. 貓咪自己的資料夾'
for d in .codex workspace chrome-profile; do install -d -o "$HANDS" -g "$HANDS" -m 0700 "/home/$HANDS/$d"; done
ok "~/.codex（Codex 登入）、~/workspace、~/chrome-profile，都只有 $HANDS 能進"

say '6. 兩個服務：貓咪的 Chrome、worker（都以 neko-hands 執行，算在它的 5 GB 裡）'
cat > /etc/systemd/system/neko-chrome.service <<EOF
[Unit]
Description=The cat's Chrome on its desktop (agent-hands H3)
After=tigervncserver@:1.service
Wants=tigervncserver@:1.service

[Service]
User=$HANDS
Slice=user-$HANDS_UID.slice
Environment=HOME=/home/$HANDS DISPLAY=:1 XAUTHORITY=/home/$HANDS/.Xauthority
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -S /tmp/.X11-unix/X1 ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/google-chrome --user-data-dir=/home/$HANDS/chrome-profile --remote-debugging-port=9222 --no-first-run --no-default-browser-check --disable-session-crashed-bubble --lang=zh-TW --window-position=0,0 --window-size=1440,900 about:blank
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/neko-hands-worker.service <<EOF
[Unit]
Description=The cat's hands: runs hands tasks from the office (agent-hands H3)
After=network-online.target neko-chrome.service
Wants=network-online.target neko-chrome.service

[Service]
User=$HANDS
Slice=user-$HANDS_UID.slice
WorkingDirectory=/home/$HANDS
Environment=HOME=/home/$HANDS LANG=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 -I $OPT/worker.py --socket /srv/neko-office/worker.sock --codex $OPT/codex/codex-x86_64-unknown-linux-musl --codex-home /home/$HANDS/.codex --workspace /home/$HANDS/workspace --handoff /srv/neko-handoff/from-cat --browser-command $OPT/mcp/node_modules/.bin/chrome-devtools-mcp --browser-arg=--browser-url=http://127.0.0.1:9222
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now neko-chrome.service >/dev/null 2>&1 || true
for _ in $(seq 1 40); do curl -s -m 2 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && break; sleep 0.5; done
version=$(curl -s -m 2 http://127.0.0.1:9222/json/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["Browser"])' 2>/dev/null || true)
[ -n "$version" ] || { journalctl -u neko-chrome.service -n 20 --no-pager >&2 || true; die '貓咪的 Chrome 沒有開起來（上面是服務日誌）。'; }
listen=$(ss -ltn | awk '$4 ~ /:9222$/ {print $4}' | sort -u | tr '\n' ' ')
case "$listen" in *127.0.0.1:9222*) ;; *) die "Chrome 除錯埠不在 127.0.0.1（$listen）。";; esac
case "$listen" in *0.0.0.0*|*'*:'*|*'[::]'*) die "Chrome 除錯埠對外開放了（$listen），停止。";; esac
ok "貓咪的 Chrome：$version，除錯埠只聽 ${listen% }，在 user-$HANDS_UID.slice 裡"
systemctl enable --now neko-hands-worker.service >/dev/null 2>&1 || true
sleep 3
[ "$(systemctl is-active neko-hands-worker.service)" = active ] || { journalctl -u neko-hands-worker.service -n 20 --no-pager >&2 || true; die 'worker 沒有啟動。'; }
ok "worker 已啟動：$(journalctl -u neko-hands-worker.service -n 1 --no-pager -o cat 2>/dev/null)"

say '7. 用貓咪的身分檢查工具'
runuser -u "$HANDS" -- test -w "$OPT/worker.py" && die '貓咪改得了 worker.py'
runuser -u "$HANDS" -- test -w "$OPT/codex/codex-x86_64-unknown-linux-musl" && die '貓咪改得了 Codex'
runuser -u "$HANDS" -- test -w "$OPT/mcp/node_modules/chrome-devtools-mcp/package.json" && die '貓咪改得了瀏覽器工具'
ok "worker、Codex、瀏覽器工具：貓咪能執行、改不了"
runuser -u "$HANDS" -- "$OPT/mcp/node_modules/.bin/chrome-devtools-mcp" --help >/dev/null 2>&1 && ok '瀏覽器工具能以 neko-hands 執行' || die '瀏覽器工具無法以 neko-hands 執行'
login=$(runuser -u "$HANDS" -- env HOME=/home/$HANDS CODEX_HOME=/home/$HANDS/.codex "$OPT/codex/codex-x86_64-unknown-linux-musl" login status 2>&1 || true)
case "$login" in *'Logged in'*) ok 'Codex 已登入';; *) printf '   · Codex 尚未登入：需要 YUI 用裝置碼登入一次（下一步）\n';; esac

say '完成'
