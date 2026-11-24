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
if ! git diff --quiet HEAD -- .; then
  echo '請先提交辦公室的修改；部署只使用已提交的來源。' >&2
  exit 2
fi
payload=$(mktemp)
trap 'rm -f "$payload"' 0 HUP INT TERM
# Export the complete committed source, including packages, helpers and test fixtures.
# Git's archive excludes untracked runtime data and account credentials.
git -C "$(git rev-parse --show-toplevel)" archive --format=tar HEAD:office > "$payload"
echo "部署辦公室來源 $(git rev-parse --short HEAD)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'umask 077; mkdir -p ~/neighbor-office/app ~/.config/systemd/user'
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'tar --no-same-owner -xf - -C ~/neighbor-office/app' < "$payload"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'cp ~/neighbor-office/app/services/neighbor-ollama.service ~/neighbor-office/app/services/neighbor-office.service ~/.config/systemd/user/'
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'python3 -I -m unittest discover -s ~/neighbor-office/app/tests -v && systemctl --user daemon-reload && systemctl --user disable neighbor-ollama.service && systemctl --user enable neighbor-office.service && systemctl --user restart neighbor-office.service'
