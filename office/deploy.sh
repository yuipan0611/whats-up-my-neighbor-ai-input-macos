#!/bin/sh
# Deploy office source and user units; external login is a separate user step.
set -eu
cd "$(dirname "$0")"
mode=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps \
  'if grep -q -- --public-origin ~/.config/systemd/user/neighbor-office.service; then echo public; else echo legacy; fi') || {
  echo '無法確認目前服務設定，已停止部署。' >&2
  exit 2
}
if [ "$mode" = public ]; then
  echo '公網手機版已啟用；此舊部署腳本會覆蓋服務設定，請使用手機版部署流程。' >&2
  exit 2
fi
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'umask 077; mkdir -p ~/neighbor-office/app ~/.config/systemd/user'
scp -q office.py telemetry.py tracing_contract.py requirements-observability.txt neighbor-vps:neighbor-office/app/
scp -qr static tests neighbor-vps:neighbor-office/app/
scp -q services/neighbor-ollama.service services/neighbor-office.service neighbor-vps:.config/systemd/user/
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'python3 -I -m unittest discover -s ~/neighbor-office/app/tests -v && systemctl --user daemon-reload && systemctl --user disable neighbor-ollama.service && systemctl --user enable neighbor-office.service && systemctl --user restart neighbor-office.service'
