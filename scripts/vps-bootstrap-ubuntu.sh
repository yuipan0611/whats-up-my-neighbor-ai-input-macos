#!/bin/bash
# Run once as root in the Hostinger web console (hPanel → VPS → Web console).
# Creates a non-sudo user "neighbor" that only the Mac key can log in to,
# installs TigerVNC + XFCE, and turns on ufw with SSH allowed.
# It does not disable root/password SSH login and does not start VNC.
set -euo pipefail

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPdzA1B3urwlcdQSAHIja5HiraA/MjZCWujMsASQrIP0 neighbor-vps 2026-10-21'

echo "== 1/4 user neighbor (no sudo, no password login)"
id neighbor >/dev/null 2>&1 || adduser --disabled-password --gecos "" neighbor
install -d -m 700 -o neighbor -g neighbor /home/neighbor/.ssh
touch /home/neighbor/.ssh/authorized_keys
grep -qxF "$PUBKEY" /home/neighbor/.ssh/authorized_keys || echo "$PUBKEY" >> /home/neighbor/.ssh/authorized_keys
chown neighbor:neighbor /home/neighbor/.ssh/authorized_keys
chmod 600 /home/neighbor/.ssh/authorized_keys

echo "== 2/4 packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y tigervnc-standalone-server tigervnc-tools xfce4 xfce4-goodies dbus-x11

echo "== 3/4 xstartup"
install -d -m 700 -o neighbor -g neighbor /home/neighbor/.vnc
cat > /home/neighbor/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chown neighbor:neighbor /home/neighbor/.vnc/xstartup
chmod 755 /home/neighbor/.vnc/xstartup

echo "== 4/4 firewall: allow SSH, nothing else inbound"
apt-get install -y ufw
ufw allow 22/tcp
ufw --force enable
ufw status verbose

echo
echo "== host key fingerprints (compare with the Mac side)"
for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done
echo
echo "Done. Next, still in this console:"
echo "  su - neighbor"
echo "  vncpasswd            # choose a VNC password (only first 8 chars count), answer n to view-only"
echo "  vncserver :1 -localhost yes -SecurityTypes VncAuth"
echo "  ss -ltn | grep 5901  # must show 127.0.0.1:5901 or [::1]:5901 only"
