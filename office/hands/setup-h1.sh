#!/usr/bin/env bash
# agent-hands H1: the root-only VPS setup for the cat's hands (office/docs/agent-hands/PRD.md 5.2, 5.7, 6, 8.2).
#
#   install -m 700 /home/neighbor/neko-h1/setup-h1.sh /root/setup-h1.sh
#   sha256sum /root/setup-h1.sh          # compare with the hash Claude gave you
#   bash /root/setup-h1.sh 2>&1 | tee /root/neko-h1.log
#
# Safe to run again: every step checks what is already there. It never prints or logs
# a secret; the generated VNC password goes only into two owner-only files.
set -euo pipefail
umask 022

OWNER=neighbor                 # the office's account (exists)
HANDS=neko-hands               # the cat's account (created here, no sudo)
GROUP=neko                     # shared by both: worker socket and handoff folders
OFFICE_DIR=/srv/neko-office    # worker.sock (the office creates it), vnc-password, h1-report.txt
HANDOFF=/srv/neko-handoff      # to-cat (office writes) and from-cat (cat writes)
SWAPFILE=/swapfile
VNC_DISPLAY=:1
REPORT_LINES=()

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; REPORT_LINES+=("OK   $*"); }
note() { printf '   · %s\n' "$*"; REPORT_LINES+=("NOTE $*"); }
die()  { printf '   ✗ %s\n' "$*" >&2; REPORT_LINES+=("FAIL $*"); write_report; exit 1; }
as_hands() { runuser -u "$HANDS" -- "$@"; }
has_word() { [[ " $1 " == *" $2 "* ]]; }   # pipes into grep -q can SIGPIPE under pipefail

write_report() {
  [ -d "$OFFICE_DIR" ] || return 0
  local tmp
  tmp=$(mktemp "$OFFICE_DIR/.h1-report.XXXXXX")
  { echo "agent-hands H1 report $(date -u +%Y-%m-%dT%H:%M:%SZ) (no secrets in this file)"; printf '%s\n' "${REPORT_LINES[@]}"; } > "$tmp"
  chown "$OWNER:$OWNER" "$tmp"; chmod 640 "$tmp"; mv -f "$tmp" "$OFFICE_DIR/h1-report.txt"
}

# ---------------------------------------------------------------- 0. preflight
say '0. 先檢查環境'
[ "$(id -u)" = 0 ] || { echo '請用 root 執行（Hostinger 網頁終端機，或 ssh root@）。' >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "這台不是 Ubuntu（$PRETTY_NAME），停止。"
[ "$(uname -m)" = x86_64 ] || die "不是 x86_64，Chrome 裝不了，停止。"
id "$OWNER" >/dev/null 2>&1 || die "找不到 $OWNER 使用者，停止。"
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 10 ] || die "根目錄只剩 ${free_gb}G，少於 10G，停止。"
ufw_status=$(ufw status 2>/dev/null || true)
[[ "$ufw_status" == *'Status: active'* ]] || die "防火牆（ufw）沒有開著；VNC 和 Chrome 除錯埠需要它擋在外面，停止。"
ok "$PRETTY_NAME，x86_64，可用空間 ${free_gb}G，防火牆開著"

# ---------------------------------------------------------------- 1. swap (D8)
say '1. 4 GB swap（記憶體不夠時先借硬碟，不直接砍程式）'
if has_word "$(swapon --show=NAME --noheadings | tr '\n' ' ')" "$SWAPFILE"; then
  ok "swap 已經開著"
else
  if [ ! -f "$SWAPFILE" ]; then
    fallocate -l 4G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=4096 status=none
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
  fi
  swapon "$SWAPFILE"
  ok "已開啟 $SWAPFILE"
fi
grep -qE "^$SWAPFILE\s" /etc/fstab || { echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab; note '已加入 /etc/fstab，重開機後仍有效'; }
echo 'vm.swappiness=10' > /etc/sysctl.d/90-neko-swap.conf
sysctl -q -p /etc/sysctl.d/90-neko-swap.conf
ok "swappiness=10（平常盡量用記憶體）"

# ---------------------------------------------------------------- 2. the cat's account (D1)
say '2. 貓咪的帳號 neko-hands（沒有 sudo、不能登入）'
getent group "$GROUP" >/dev/null || groupadd "$GROUP"
if ! id "$HANDS" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --user-group --comment 'Cat hands (agent-hands H1)' "$HANDS"
  note "已建立 $HANDS"
fi
passwd -l "$HANDS" >/dev/null 2>&1 || true
usermod -aG "$GROUP" "$HANDS"
usermod -aG "$GROUP" "$OWNER"
chmod 750 "/home/$HANDS"
for g in sudo admin adm docker lxd wheel; do
  if has_word "$(id -nG "$HANDS")" "$g"; then gpasswd -d "$HANDS" "$g" >/dev/null; note "已把 $HANDS 移出 $g"; fi
done
[ ! -e "/home/$HANDS/.ssh/authorized_keys" ] || die "$HANDS 有 SSH 金鑰，跟設計不符，停止。"
loginctl enable-linger "$HANDS"
HANDS_UID=$(id -u "$HANDS")
ok "$HANDS（uid $HANDS_UID）只在群組：$(id -nG "$HANDS")；密碼已鎖、沒有 SSH 金鑰"

# ---------------------------------------------------------------- 3. memory ceiling for everything the cat runs
say '3. 貓咪最多用 5 GB 記憶體（就算 Chrome 吃太多，辦公室也不受影響）'
mkdir -p "/etc/systemd/system/user-$HANDS_UID.slice.d"
cat > "/etc/systemd/system/user-$HANDS_UID.slice.d/50-neko-limits.conf" <<EOF
# agent-hands H1: the cat's processes (Chrome, Codex, desktop) share this ceiling.
[Slice]
MemoryHigh=4G
MemoryMax=5G
CPUWeight=50
EOF
systemctl daemon-reload
[ "$(systemctl show "user-$HANDS_UID.slice" -p MemoryMax --value)" = 5368709120 ] || die "記憶體上限沒有生效。"
ok "user-$HANDS_UID.slice：MemoryHigh 4G、MemoryMax 5G、CPU 權重 50"

# ---------------------------------------------------------------- 4. shared folders (PRD 5.7, 9.1)
say '4. 共用資料夾：worker 入口、交接資料夾'
install -d -o "$OWNER" -g "$GROUP" -m 2750 "$OFFICE_DIR"
install -d -o root -g "$GROUP" -m 0750 "$HANDOFF"
install -d -o "$OWNER" -g "$GROUP" -m 2750 "$HANDOFF/to-cat"
install -d -o "$HANDS" -g "$GROUP" -m 2750 "$HANDOFF/from-cat"
ok "$OFFICE_DIR（$OWNER:$GROUP 2750）：辦公室在這裡開 worker.sock"
ok "$HANDOFF/to-cat 只有 $OWNER 能寫；$HANDOFF/from-cat 只有 $HANDS 能寫；兩邊都能讀"

# ---------------------------------------------------------------- 5. the desktop moves to the cat (D2)
say '5. 桌面改歸貓咪：關掉 neighbor 的桌面，:1 交給 neko-hands'
# neighbor's hand-started desktop would let the cat's account reach a neighbor session on 127.0.0.1:5901.
if pgrep -u "$OWNER" -f "Xtigervnc $VNC_DISPLAY" >/dev/null; then
  runuser -l "$OWNER" -c "tigervncserver -kill $VNC_DISPLAY" >/dev/null 2>&1 || pkill -u "$OWNER" -f "Xtigervnc $VNC_DISPLAY" || true
  sleep 2
  if pgrep -u "$OWNER" -f Xtigervnc >/dev/null; then die "neighbor 的桌面關不掉，停止。"; fi
  note "已關掉 neighbor 的桌面"
fi
if ! pgrep -f "Xtigervnc $VNC_DISPLAY" >/dev/null; then
  rm -f /tmp/.X1-lock /tmp/.X11-unix/X1   # left behind if the old desktop did not exit cleanly
fi
MANDATORY=/etc/tigervnc/vncserver-config-mandatory
if ! grep -q 'agent-hands H1' "$MANDATORY"; then
  cat >> "$MANDATORY" <<'EOF'

# --- agent-hands H1: security policy, overrides every user's config.pl ---
$localhost = "yes";
$SecurityTypes = "VncAuth";
1;
EOF
fi
ok "VNC 只聽本機、只用密碼驗證（寫在 root 擁有的 $MANDATORY）"
VNC_DIR="/home/$HANDS/.config/tigervnc"
install -d -o "$HANDS" -g "$HANDS" -m 0700 "/home/$HANDS/.config" "$VNC_DIR"
if [ ! -s "$VNC_DIR/passwd" ] || [ ! -s "$OFFICE_DIR/vnc-password" ]; then
  pw=$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(8)))')
  printf '%s\n' "$pw" | vncpasswd -f > "$VNC_DIR/passwd.new"
  chown "$HANDS:$HANDS" "$VNC_DIR/passwd.new"; chmod 600 "$VNC_DIR/passwd.new"; mv -f "$VNC_DIR/passwd.new" "$VNC_DIR/passwd"
  (umask 077; printf '%s' "$pw" > "$OFFICE_DIR/vnc-password.new")
  chown "$OWNER:$OWNER" "$OFFICE_DIR/vnc-password.new"; mv -f "$OFFICE_DIR/vnc-password.new" "$OFFICE_DIR/vnc-password"
  unset pw
  note "已產生新的 8 字元 VNC 密碼（沒有顯示；在 $OFFICE_DIR/vnc-password，只有 $OWNER 讀得到）"
fi
cat > "$VNC_DIR/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
printf '$geometry = "1440x900";\n$session = "xfce";\n1;\n' > "$VNC_DIR/config.pl"
chown "$HANDS:$HANDS" "$VNC_DIR/xstartup" "$VNC_DIR/config.pl"; chmod 755 "$VNC_DIR/xstartup"; chmod 644 "$VNC_DIR/config.pl"
USERS=/etc/tigervnc/vncserver.users
other=$(grep -E "^\s*$VNC_DISPLAY=" "$USERS" | grep -v "=$HANDS\s*$" || true)
[ -z "$other" ] || die "$USERS 已經把 $VNC_DISPLAY 指給別人：$other"
grep -qE "^\s*$VNC_DISPLAY=$HANDS\s*$" "$USERS" || echo "$VNC_DISPLAY=$HANDS" >> "$USERS"
systemctl enable "tigervncserver@$VNC_DISPLAY" >/dev/null 2>&1 || die "無法設定開機自動啟動貓咪的桌面。"
systemctl restart "tigervncserver@$VNC_DISPLAY" || true
for _ in $(seq 1 30); do pgrep -u "$HANDS" -f "Xtigervnc $VNC_DISPLAY" >/dev/null && break; sleep 0.5; done
if ! pgrep -u "$HANDS" -f "Xtigervnc $VNC_DISPLAY" >/dev/null; then
  journalctl -u "tigervncserver@$VNC_DISPLAY" -n 20 --no-pager >&2 || true
  die "貓咪的桌面沒有啟動（上面是服務日誌）。"
fi
sleep 1
listen=$(ss -ltn | awk '$4 ~ /:5901$/ {print $4}' | sort -u | tr '\n' ' ')
[ -n "$listen" ] || die "貓咪的桌面啟動了，但沒有在 5901 監聽。"
case "$listen" in *0.0.0.0*|*'*:'*|*'[::]'*) die "VNC 對外開放了（$listen），停止。";; esac
ok "貓咪的桌面已啟動（$VNC_DISPLAY，只聽 ${listen% }），開機會自動啟動"

# ---------------------------------------------------------------- 6. fonts and Chrome
say '6. 中文字型與 Google Chrome（Google 官方套件，之後由它自己的套件庫更新）'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates fonts-noto-cjk >/dev/null
ok "fonts-noto-cjk（截圖裡的中文不會變成方塊）"
if ! command -v google-chrome >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  curl -fsSLo "$tmp/google-chrome-stable_current_amd64.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y -qq "$tmp/google-chrome-stable_current_amd64.deb" >/dev/null
  rm -rf "$tmp"
fi
apt-get update -qq || die "安裝 Chrome 之後 apt 更新出錯（套件庫設定衝突？）。"
ok "$(google-chrome --version)；之後由 Google 的套件庫簽章更新"

# ---------------------------------------------------------------- 7. checks as the cat (PRD 13.1, ADR-001 A07 A11 A18)
say '7. 用貓咪的身分檢查：碰不到的就要碰不到'
if as_hands test -r "/home/$OWNER" || as_hands test -x "/home/$OWNER"; then die "$HANDS 進得了 /home/$OWNER"; fi
ok "進不了 /home/$OWNER（生活紀錄、配對、SSH 金鑰都在裡面）"
if as_hands python3 -c "import socket; socket.socket(socket.AF_UNIX).connect('/home/$OWNER/neighbor-office/run/office.sock')" 2>/dev/null; then
  die "$HANDS 連得上辦公室的本機入口"
fi
ok "連不上辦公室的本機入口（私有 socket）"
code=$(as_hands curl -s -o /dev/null -w '%{http_code}' -H 'Host: 127.0.0.1:8421' http://127.0.0.1:8421/api/bootstrap || true)
[ "$code" = 421 ] || die "從 $HANDS 打辦公室的本機 TCP 得到 $code，應該是 421"
ok "假裝本機去敲辦公室：421（0.4.0 的修補在跨使用者下也有效）"
if as_hands test -r "$OFFICE_DIR/vnc-password"; then die "$HANDS 讀得到 VNC 密碼"; fi
ok "讀不到 VNC 密碼"
if [ -S /var/run/docker.sock ] && as_hands test -w /var/run/docker.sock; then die "$HANDS 能用 Docker"; fi
sudo_list=$(sudo -n -l -U "$HANDS" 2>&1 || true)
[[ "$sudo_list" != *'may run'* ]] || die "$HANDS 有 sudo 權限"
ok "沒有 sudo、不能用 Docker"
if as_hands touch "$HANDOFF/to-cat/.h1-probe" 2>/dev/null; then rm -f "$HANDOFF/to-cat/.h1-probe"; die "$HANDS 能寫 to-cat"; fi
as_hands touch "$HANDOFF/from-cat/.h1-probe" || die "$HANDS 不能寫 from-cat"
runuser -u "$OWNER" -- test -r "$HANDOFF/from-cat/.h1-probe" || die "$OWNER 讀不到 from-cat"
rm -f "$HANDOFF/from-cat/.h1-probe"
runuser -u "$OWNER" -- touch "$HANDOFF/to-cat/.h1-probe" || die "$OWNER 不能寫 to-cat"
as_hands test -r "$HANDOFF/to-cat/.h1-probe" || die "$HANDS 讀不到 to-cat"
rm -f "$HANDOFF/to-cat/.h1-probe"
ok "交接資料夾的方向正確（各寫各的，彼此看得到）"
if as_hands curl -s -m 3 -o /dev/null http://169.254.169.254/; then note "雲端 metadata 端點連得到（ADR-001 A11，H3 要處理）"; else ok "雲端 metadata 端點連不到"; fi
ufw_status=$(ufw status 2>/dev/null || true)
if grep -qE '^(5901|9222)\b' <<<"$ufw_status"; then die "防火牆開了 5901 或 9222"; fi
ok "防火牆沒有開放 VNC（5901）或 Chrome 除錯埠（9222）"
health=$(runuser -u "$OWNER" -- curl -s --unix-socket "/home/$OWNER/neighbor-office/run/office.sock" -H 'Host: 127.0.0.1:18421' http://127.0.0.1:18421/api/health || true)
[[ "$health" == *'"service": "neighbor-office"'* ]] || die "辦公室的健康檢查沒有回應。"
ok "辦公室照常運作"
ok "swap：$(swapon --show=NAME,SIZE --noheadings | tr -s ' ' | tr '\n' ' ')"

write_report
say '完成'
echo "   結果也存在 $OFFICE_DIR/h1-report.txt（沒有密碼）。回到聊天告訴 Claude「H1 跑完了」。"
