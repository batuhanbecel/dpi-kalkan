#!/bin/zsh
# Evrensel (Apple Silicon + Intel) sürüm derlemesi yapıp "DPI Kalkan.app" paketini build/ klasörüne üretir.
# --zip verilirse paylaşım için build/DPI-Kalkan.zip de oluşturur.
#
# İmza: anahtar zincirinde "Developer ID Application" sertifikası varsa onunla (hardened runtime +
# zaman damgası) imzalar, yoksa ad-hoc imzalar. SIGN_IDENTITY ile kimlik elle seçilebilir.
# Noterleme: Developer ID ile --zip derlemesinde, NOTARY_PROFILE (varsayılan "dpi-kalkan") adlı
# notarytool profiliyle Apple'a gönderir ve sonucu pakete zımbalar. Atlamak için NOTARIZE=0.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.2.0"
ARCHS=(--arch arm64 --arch x86_64)
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-dpi-kalkan}"

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

if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "İmzalandı: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Developer ID sertifikası bulunamadı; ad-hoc imzalandı (indirenler ilk açılışta uyarı görür)."
fi
codesign --verify --deep --strict "$APP"
echo "Hazır: $PWD/$APP"

[[ "${1:-}" == "--zip" ]] || exit 0

ZIP="build/DPI-Kalkan.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "$IDENTITY" && "${NOTARIZE:-1}" != "0" ]]; then
    echo "Noterleme için Apple'a gönderiliyor ($NOTARY_PROFILE)…"
    if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "Noterleme başarısız. Profil yoksa bir kez şunu çalıştır:" >&2
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
fi
echo "Arşiv: $PWD/$ZIP"
