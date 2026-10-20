#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
package_dir="$project_dir"
swift build --package-path "$package_dir" -c release
bin_dir=$(swift build --package-path "$package_dir" -c release --show-bin-path)
app_dir="$package_dir/dist/WindowBridge.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/WindowBridge" "$app_dir/Contents/MacOS/WindowBridge"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WindowBridge</string>
<key>CFBundleDisplayName</key><string>WindowBridge</string>
<key>CFBundleIdentifier</key><string>local.codex.WindowBridge</string>
<key>CFBundleExecutable</key><string>WindowBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>열린 창의 썸네일을 로컬 창 전환 패널에 표시합니다. 화면은 저장하거나 전송하지 않습니다.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
print -r -- "$app_dir"
