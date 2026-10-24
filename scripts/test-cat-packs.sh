#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/build/cat-packs-fixtures" "$ROOT/build/cat-packs"
python3 "$ROOT/Tests/make_cat_pack_fixtures.py" "$ROOT/build/cat-packs-fixtures"
swiftc -O -swift-version 5 -framework ImageIO \
  "$ROOT/Sources/GroqVoiceInput/CatAppearance.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatConfiguration.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatCoatSelection.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatPack.swift" \
  "$ROOT/Tests/CatPackTests.swift" \
  -o "$ROOT/build/CatPackTests"
"$ROOT/build/CatPackTests" "$ROOT/build/cat-packs-fixtures" "$ROOT/build/cat-packs/Mochi.nekocat"
swiftc -O -swift-version 5 -framework ImageIO \
  "$ROOT/Sources/GroqVoiceInput/CatAppearance.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatConfiguration.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatCoatSelection.swift" \
  "$ROOT/Sources/GroqVoiceInput/CatPack.swift" \
  "$ROOT/Tests/CatPackActivationTests.swift" \
  -o "$ROOT/build/CatPackActivationTests"
"$ROOT/build/CatPackActivationTests" "$ROOT/build/cat-packs-fixtures"
