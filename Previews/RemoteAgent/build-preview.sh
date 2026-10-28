#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
SOURCE="$ROOT/Previews/RemoteAgent"
OUTPUT="$ROOT/build/remote-agent-preview"
APP="$OUTPUT/遠端分身預覽.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tw.panh.NeighborRemoteAgentPreview</string>
<key>CFBundleName</key><string>遠端分身預覽</string>
<key>CFBundleExecutable</key><string>NeighborRemoteAgentPreview</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
PREVIEW_ARCH="$(uname -m)"
CORE_SOURCES=("$ROOT"/Sources/NeighborAgentCore/*.swift)
swiftc -target "$PREVIEW_ARCH-apple-macos13.0" -swift-version 5 \
  -framework AppKit -framework SwiftUI -framework Combine \
  "${CORE_SOURCES[@]}" \
  "$SOURCE/PreviewModel.swift" "$SOURCE/RemoteDesktopHandoffModel.swift" "$SOURCE/RemoteAgentView.swift" \
  "$SOURCE/PreviewRenderer.swift" "$SOURCE/PreviewMain.swift" \
  -o "$APP/Contents/MacOS/NeighborRemoteAgentPreview"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
print -r -- "$APP"
