#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang"
swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" -c release
APP="$PWD/dist/CodexSpeed.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift scripts/generate-icon.swift "$PWD/Assets"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/CodexSpeed "$APP/Contents/MacOS/CodexSpeed.new"
mv -f "$APP/Contents/MacOS/CodexSpeed.new" "$APP/Contents/MacOS/CodexSpeed"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexSpeed</string>
<key>CFBundleIdentifier</key><string>local.codexspeed.hud</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>CodexSpeed</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
.build/release/CodexSpeed --export-pricing > dist/ccusage-pricing.json
printf '%s\n' "$APP"
