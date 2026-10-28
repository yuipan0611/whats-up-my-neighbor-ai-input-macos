#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 -framework Combine \
  "$ROOT/Sources/NeighborAgentCore/SSHTunnel.swift" \
  "$ROOT/Sources/NeighborAgentCore/RemoteDesktopHandoff.swift" \
  "$ROOT/Previews/RemoteAgent/RemoteDesktopHandoffModel.swift" \
  "$ROOT/Tests/RemoteDesktopHandoffTests.swift" -o "$ROOT/build/RemoteDesktopHandoffTests"
"$ROOT/build/RemoteDesktopHandoffTests"
