# Sandbox image for runner_docker.DockerRunner (tasks/H3-runner-docker-v1.md).
# What the runner needs: git, coreutils timeout and sleep, sh, a user 10001 and a /work folder it owns.
# Python and pip are here for common tasks; anything else a task needs it may install at run time (network is allowed).
# Nothing secret goes into this image: no keys, no tokens, no copied host files.
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 neko \
 && useradd --uid 10001 --gid 10001 --home-dir /tmp --no-create-home --shell /bin/sh neko \
 && mkdir /work && chown 10001:10001 /work

USER 10001:10001
WORKDIR /work
ENV HOME=/tmp PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
