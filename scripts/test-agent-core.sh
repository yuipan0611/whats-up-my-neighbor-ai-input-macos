#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 \
  "$ROOT/Sources/NeighborAgentCore/AgentTypes.swift" \
  "$ROOT/Sources/NeighborAgentCore/AgentTaskCoordinator.swift" \
  "$ROOT/Sources/NeighborAgentCore/DemoAgentTransport.swift" \
  "$ROOT/Tests/AgentCoreTests.swift" -o "$ROOT/build/AgentCoreTests"
"$ROOT/build/AgentCoreTests"
