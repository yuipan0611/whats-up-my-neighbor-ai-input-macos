FROM debian:bookworm-slim

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server \
        tigervnc-standalone-server \
        tigervnc-common \
        tigervnc-tools \
        xfce4 \
        xfce4-goodies \
        dbus-x11 \
        iproute2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash neighbor && \
    mkdir -p /run/sshd /etc/ssh/sshd_config.d && \
    printf "%s\n" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PermitRootLogin no" \
        "AllowTcpForwarding local" \
        "PermitOpen 127.0.0.1:5901" \
        "X11Forwarding no" \
        "AllowAgentForwarding no" \
        > /etc/ssh/sshd_config.d/neighbor.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
