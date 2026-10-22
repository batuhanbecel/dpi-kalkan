#!/bin/zsh
# Resources/AppIcon.icon (Icon Composer belgesi) → .build/icon/Assets.car + AppIcon.icns
# macOS 26 ve sonrası Liquid Glass ikonu Assets.car'dan okur; cam, specular parlama ve
# açık/koyu/renkli varyantları sistem üretir. actool eski sürümler için .icns de çıkarır.
set -euo pipefail
cd "$(dirname "$0")/.."

ACTOOL="$(xcode-select -p)/usr/bin/actool"
OUT=".build/icon"
[[ -x "$ACTOOL" ]] || { echo "actool bulunamadı, Xcode kurulu mu?" >&2; exit 1 }

# actool bir asset kataloğu ister; ikon belgesi ona ek girdi olarak verilir.
CATALOG="$OUT/Assets.xcassets"
rm -rf "$OUT"
mkdir -p "$CATALOG"
print '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$CATALOG/Contents.json"

"$ACTOOL" \
  --compile "$OUT" \
  --app-icon AppIcon \
  --output-partial-info-plist "$OUT/partial.plist" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --target-device mac \
  "$CATALOG" Resources/AppIcon.icon > "$OUT/actool.log" 2>&1

if [[ ! -f "$OUT/Assets.car" || ! -f "$OUT/AppIcon.icns" ]]; then
  echo "İkon derlenemedi:" >&2
  cat "$OUT/actool.log" >&2
  exit 1
fi
echo "İkon derlendi: $OUT/Assets.car, $OUT/AppIcon.icns"
