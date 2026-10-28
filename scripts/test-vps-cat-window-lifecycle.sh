#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build/cat-render"
swiftc -swift-version 5 -D DESKTOP_PET_TESTS -framework AppKit -framework SwiftUI -framework WebKit -framework Combine -framework ApplicationServices -framework QuartzCore \
  "$ROOT"/Sources/GroqVoiceInput/DesktopPet*.swift \
  "$ROOT/Sources/GroqVoiceInput/CatAppearance.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatAnatomy.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatAppearanceArtwork.swift" \
  "$ROOT"/Sources/GroqVoiceInput/VPS*.swift \
  "$ROOT/Tests/VPSCatWindowLifecycleTests.swift" -o "$ROOT/build/VPSCatWindowLifecycleTests"
"$ROOT/build/VPSCatWindowLifecycleTests" "$ROOT/Resources/DesktopPet"
