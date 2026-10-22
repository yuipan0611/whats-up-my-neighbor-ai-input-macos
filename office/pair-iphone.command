#!/bin/zsh
set -euo pipefail

echo '正在確認貓咪辦公室的安全連線…'
if ! /usr/bin/curl -fsS --max-time 8 -o /dev/null https://office.nekonode.cloud/; then
  echo '目前無法連到 office.nekonode.cloud，請稍後再試。'
  read -r '?按 Return 關閉視窗…'
  exit 1
fi

echo '以下配對碼只顯示在這台 Mac，請在 10 分鐘內輸入 iPhone Chrome 的配對頁。'
echo '不要把配對碼貼到聊天或傳給其他人。'
if ! /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps \
  'python3 -I ~/neighbor-office/current/office.py pair'; then
  echo '無法產生配對碼。請確認 Mac 可以連到 VPS。'
  read -r '?按 Return 關閉視窗…'
  exit 1
fi

echo '輸入手機後，可關閉此視窗。'
read -r '?按 Return 關閉視窗…'
