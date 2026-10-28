#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build/agent-preview-tests"
swiftc -swift-version 5 -framework Combine \
  "$ROOT/Sources/NeighborAgentCore/AgentTypes.swift" \
  "$ROOT/Sources/NeighborAgentCore/AgentTaskCoordinator.swift" \
  "$ROOT/Sources/NeighborAgentCore/DemoAgentTransport.swift" \
  "$ROOT/Previews/RemoteAgent/PreviewModel.swift" \
  "$ROOT/Tests/AgentPreviewTests.swift" -o "$ROOT/build/AgentPreviewTests"
"$ROOT/build/AgentPreviewTests" "$ROOT/build/agent-preview-tests"
