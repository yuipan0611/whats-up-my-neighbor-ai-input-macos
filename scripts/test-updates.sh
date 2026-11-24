#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 "$ROOT/Sources/GroqVoiceInput/UpdateReminderPolicy.swift" "$ROOT/Sources/GroqVoiceInput/UpdateDiagnostics.swift" \
  "$ROOT/Tests/UpdateReminderPolicyTests.swift" -o "$ROOT/build/UpdateReminderPolicyTests"
"$ROOT/build/UpdateReminderPolicyTests"
swiftc -swift-version 5 "$ROOT/Sources/GroqVoiceInput/OldAppBackupCleanup.swift" "$ROOT/Sources/GroqVoiceInput/UpdateDiagnostics.swift" \
  "$ROOT/Tests/OldAppBackupCleanupProbe.swift" -o "$ROOT/build/OldAppBackupCleanupProbe"
python3 "$ROOT/Tests/test_release_contract.py"
