#!/bin/sh
set -eu

cp /run/neighbor/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
chown root:root /etc/ssh/ssh_host_ed25519_key
chmod 600 /etc/ssh/ssh_host_ed25519_key

cp /run/neighbor/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
chown root:root /etc/ssh/ssh_host_ed25519_key.pub
chmod 644 /etc/ssh/ssh_host_ed25519_key.pub

mkdir -p /home/neighbor/.ssh
chmod 700 /home/neighbor/.ssh
cp /run/neighbor/authorized_keys /home/neighbor/.ssh/authorized_keys
chmod 600 /home/neighbor/.ssh/authorized_keys
chown -R neighbor:neighbor /home/neighbor/.ssh

mkdir -p /home/neighbor/.vnc
chmod 700 /home/neighbor/.vnc
chown neighbor:neighbor /home/neighbor/.vnc

su neighbor -c 'vncpasswd -f < /run/neighbor/vnc-password > ~/.vnc/passwd'
chmod 600 /home/neighbor/.vnc/passwd
chown neighbor:neighbor /home/neighbor/.vnc/passwd

cat << 'EOF' > /home/neighbor/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x /home/neighbor/.vnc/xstartup
chown neighbor:neighbor /home/neighbor/.vnc/xstartup

su - neighbor -c 'vncserver :1 -localhost yes -SecurityTypes VncAuth'

ss -ltn

exec /usr/sbin/sshd -D -e
