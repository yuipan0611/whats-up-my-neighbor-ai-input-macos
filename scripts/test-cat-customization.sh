#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build/appearance"
swiftc -O -swift-version 5 -D DESKTOP_PET_TESTS -D CAT_CUSTOMIZATION_TESTS \
  -framework AppKit -framework ApplicationServices -framework QuartzCore \
  "$ROOT"/Sources/GroqVoiceInput/DesktopPet*.swift \
  "$ROOT/Sources/GroqVoiceInput/CatAppearance.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatAnatomy.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatAppearanceArtwork.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatCustomizationWindowController.swift" \
  "$ROOT/Tests/CatCustomizationTests.swift" \
  -o "$ROOT/build/CatCustomizationTests"
"$ROOT/build/CatCustomizationTests" "$ROOT" "$ROOT/build/appearance"
