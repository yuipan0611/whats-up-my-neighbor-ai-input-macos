FROM node:22-bookworm-slim
ARG CODEX_VERSION=0.163.0
RUN apt-get update && apt-get install -y --no-install-recommends python3 git bash ca-certificates bubblewrap util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 agent \
    && mkdir -p /run/private && chmod 700 /run/private \
    && npm install -g "@openai/codex@${CODEX_VERSION}" "@openai/codex-responses-api-proxy@${CODEX_VERSION}" \
    && npm cache clean --force
WORKDIR /app
COPY runner.py adapter.sh codex_adapter.py ./
# Coordinator/proxy retain the root-only mounted key; Codex runs as uid 10001.
# There is no sudo and no automatic sandbox bypass.
ENTRYPOINT ["python3", "/app/runner.py"]
