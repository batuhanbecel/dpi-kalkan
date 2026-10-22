#!/bin/zsh
# Evrensel (Apple Silicon + Intel) sürüm derlemesi yapıp "DPI Kalkan.app" paketini build/ klasörüne üretir.
# --zip verilirse paylaşım için build/DPI-Kalkan.zip de oluşturur.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.1.0"
ARCHS=(--arch arm64 --arch x86_64)

./Scripts/compile-icon.sh
swift build -c release --product DPIKalkan "${ARCHS[@]}"
BIN="$(swift build -c release --product DPIKalkan "${ARCHS[@]}" --show-bin-path)/DPIKalkan"

APP="build/DPI Kalkan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DPIKalkan"
cp .build/icon/Assets.car .build/icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DPI Kalkan</string>
    <key>CFBundleDisplayName</key><string>DPI Kalkan</string>
    <key>CFBundleIdentifier</key><string>com.batuhan.dpikalkan</string>
    <key>CFBundleExecutable</key><string>DPIKalkan</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>tr</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT Lisansı</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Hazır: $PWD/$APP"

if [[ "${1:-}" == "--zip" ]]; then
    rm -f build/DPI-Kalkan.zip
    ditto -c -k --keepParent "$APP" build/DPI-Kalkan.zip
    echo "Arşiv: $PWD/build/DPI-Kalkan.zip"
fi
