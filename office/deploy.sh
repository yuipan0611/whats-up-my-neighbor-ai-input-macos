#!/bin/sh
# Deploy office source and user units; external login is a separate user step.
set -eu
cd "$(dirname "$0")"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'umask 077; mkdir -p ~/neighbor-office/app ~/.config/systemd/user'
scp -q office.py neighbor-vps:neighbor-office/app/office.py
scp -qr static tests neighbor-vps:neighbor-office/app/
scp -q services/neighbor-ollama.service services/neighbor-office.service neighbor-vps:.config/systemd/user/
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes neighbor-vps 'python3 -I -m unittest discover -s ~/neighbor-office/app/tests -v && systemctl --user daemon-reload && systemctl --user disable neighbor-ollama.service && systemctl --user enable neighbor-office.service && systemctl --user restart neighbor-office.service'
