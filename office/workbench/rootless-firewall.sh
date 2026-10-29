#!/bin/sh
# Runs inside the rootless Docker network/user namespace, never the host namespace.
set -eu
export DOCKER_HOST=unix:///run/user/1000/docker.sock
export XTABLES_LOCKFILE=/run/user/1000/neko-xtables.lock
docker network inspect neko-runner >/dev/null 2>&1 || docker network create --subnet 172.30.250.0/24 neko-runner >/dev/null
neko_pid=$(cat /run/user/1000/dockerd-rootless/child_pid)
case "$neko_pid" in ''|*[!0-9]*) exit 1;; esac
ipt() { nsenter -U -n -t "$neko_pid" -- iptables -w 5 "$@"; }
ipt -N NEKO-EGRESS 2>/dev/null || true
ipt -F NEKO-EGRESS
ipt -A NEKO-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# slirp4netns DNS resolver only; no other private address/port is allowed.
ipt -A NEKO-EGRESS -d 10.0.2.3 -p udp --dport 53 -j ACCEPT
ipt -A NEKO-EGRESS -d 10.0.2.3 -p tcp --dport 53 -j ACCEPT
for neko_dest in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 31.97.108.187/32; do
  ipt -A NEKO-EGRESS -d "$neko_dest" -j DROP
done
ipt -A NEKO-EGRESS -j RETURN
ipt -C DOCKER-USER -s 172.30.250.0/24 -j NEKO-EGRESS 2>/dev/null || ipt -I DOCKER-USER 1 -s 172.30.250.0/24 -j NEKO-EGRESS
ipt -C INPUT -s 172.30.250.0/24 -j DROP 2>/dev/null || ipt -I INPUT 1 -s 172.30.250.0/24 -j DROP
