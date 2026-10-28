#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 "$ROOT/Sources/NeighborAgentCore/SSHTunnel.swift" \
  "$ROOT/Tests/AgentSSHTests.swift" -o "$ROOT/build/AgentSSHTests"
"$ROOT/build/AgentSSHTests"
# Parse with the real system SSH, but -G never connects and -F /dev/null skips
# user/system config (including Match exec). The destination is a dummy alias.
python3 - "$ROOT/build/AgentSSHTests" <<'PY'
import json, subprocess, sys
args=json.loads(subprocess.check_output([sys.argv[1], '--arguments-json'], text=True))
r=subprocess.run(['/usr/bin/ssh', '-G', '-F', '/dev/null', *args], capture_output=True, text=True)
assert r.returncode == 0, r.stderr
assert 'stricthostkeychecking true' in r.stdout or 'stricthostkeychecking yes' in r.stdout
assert 'localforward 127.0.0.1:18421 [127.0.0.1]:8421' in r.stdout or 'localforward [127.0.0.1]:18421 [127.0.0.1]:8421' in r.stdout
print('System SSH argument parsing passed (-G only; no connection)')
PY
