#!/bin/bash
# Builds dist/Tempo.app and dist/Tempo.zip.
# Optional: DEVELOPER_ID="Developer ID Application: …" to sign for sharing,
#           NOTARY_PROFILE=<notarytool keychain profile> to notarise.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="dist/Tempo.app"

if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tempo"
else
  echo "Universal build failed; building for this Mac only."
  swift build -c release
  BIN=".build/release/Tempo"
fi

rm -rf "$APP" dist/Tempo.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/Tempo"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tempo</string>
  <key>CFBundleDisplayName</key><string>Tempo</string>
  <key>CFBundleIdentifier</key><string>app.tempo.menubar</string>
  <key>CFBundleExecutable</key><string>Tempo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
elif security find-certificate -c "Tempo Local Signing" >/dev/null 2>&1; then
  # Same signature on every build: macOS keeps the Keychain "Always Allow" (scripts/make-signing-cert.sh).
  codesign --force --sign "Tempo Local Signing" "$APP"
else
  codesign --force --sign - "$APP"   # Ad hoc: the Keychain asks again after each build.
fi

ditto -c -k --keepParent "$APP" dist/Tempo.zip

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit dist/Tempo.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/Tempo.zip && ditto -c -k --keepParent "$APP" dist/Tempo.zip
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Tempo")) and dist/Tempo.zip"
