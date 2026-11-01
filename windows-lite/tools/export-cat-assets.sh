#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
mkdir -p "$ROOT/build/windows-lite"
swiftc -O -framework AppKit \
 "$ROOT/Sources/GroqVoiceInput/CatAppearance.swift" \
 "$ROOT/Sources/GroqVoiceInput/CatAnatomy.swift" \
 "$ROOT/Sources/GroqVoiceInput/CatAppearanceArtwork.swift" \
 "$ROOT/windows-lite/tools/ExportCatAssets.swift" -o "$ROOT/build/windows-lite/export-cat-assets"
"$ROOT/build/windows-lite/export-cat-assets" "$ROOT"
python3 - "$ROOT/windows-lite/NekoChat.Windows/Assets" <<'PY'
import gzip,sys
from pathlib import Path
for p in Path(sys.argv[1]).glob('*.bin'):
    p.with_suffix('.bin.gz').write_bytes(gzip.compress(p.read_bytes(),mtime=0))
    p.unlink()
PY
