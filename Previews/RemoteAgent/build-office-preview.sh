#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
SOURCE="$ROOT/Previews/RemoteAgent"
APP="$ROOT/build/office-preview/貓咪辦公室預覽.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The approved white icon source stays outside this checkout's older resources.
cp "$ROOT/../neighbor-remote-approved-cat-icons/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tw.panh.NeighborOfficePreview</string>
<key>CFBundleName</key><string>貓咪辦公室預覽</string>
<key>CFBundleExecutable</key><string>NeighborOfficePreview</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
PREVIEW_ARCH="$(uname -m)"
swiftc -target "$PREVIEW_ARCH-apple-macos13.0" -swift-version 5 \
  -framework AppKit -framework SwiftUI -framework Combine -framework WebKit \
  "$ROOT"/Sources/NeighborAgentCore/*.swift \
  "$SOURCE/PreviewModel.swift" "$SOURCE/RemoteDesktopHandoffModel.swift" "$SOURCE/RemoteAgentView.swift" \
  "$SOURCE/OfficePanelView.swift" "$SOURCE/OfficePreviewMain.swift" \
  -o "$APP/Contents/MacOS/NeighborOfficePreview"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
print -r -- "$APP"
