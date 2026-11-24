FROM node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv python3-pip git ca-certificates coreutils \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 neko \
 && useradd --uid 10001 --gid 10001 --home-dir /tmp --no-create-home --shell /bin/sh neko \
 && mkdir /work && chown 10001:10001 /work
USER 10001:10001
WORKDIR /work
ENV HOME=/tmp LANG=C.UTF-8 CI=1 NEXT_TELEMETRY_DISABLED=1
