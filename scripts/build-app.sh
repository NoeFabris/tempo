#!/bin/bash
# Builds dist/Tempo.app and dist/Tempo.zip: a universal, ad hoc signed app with Sparkle embedded.
#   VERSION=1.2.0    marketing and bundle version (default: newest tag without "v", else 0.0.0)
#   REPO=owner/repo  GitHub repository for the Sparkle feed URL
#   ARCHS=host       build only for this Mac (default: universal)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-NoeFabris/tempo}"
# "|| true": without a tag, git fails, and pipefail plus set -e would end the script silently here.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
ARCHS="${ARCHS:-universal}"
# Public half of the Sparkle EdDSA key. The private half lives in the maintainer's login Keychain,
# the GitHub secret SPARKLE_PRIVATE_KEY and the password manager. See docs/release.md.
SU_PUBLIC_ED_KEY="3Qy/kO4gcVbNYDMuHJsZpBuK3PXawtCNvNoAFIcPHNQ="
FEED_URL="https://github.com/${REPO}/releases/latest/download/appcast.xml"
APP="dist/Tempo.app"
ZIP="dist/Tempo.zip"

fail() { echo "build-app: $*" >&2; exit 1; }
[[ "$SU_PUBLIC_ED_KEY" != "REPLACE_ME" ]] || fail "SU_PUBLIC_ED_KEY is not set (see docs/release.md)"

ARCH_FLAGS="--arch arm64 --arch x86_64"
[[ "$ARCHS" != "host" ]] || ARCH_FLAGS=""
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Tempo" "$APP/Contents/MacOS/Tempo"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
# ditto keeps the symlinks and executable bits inside the framework; Sparkle's installer needs them.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM links @rpath/Sparkle.framework but adds no rpath for it. (Older toolchains warn that this
# invalidates the linker's signature; codesign below replaces it in any case.)
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Tempo"

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
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Ad hoc. No hardened runtime: library validation would reject the ad hoc signed Sparkle.framework.
codesign --force --sign - "$APP"

# Self-checks. A broken bundle must never reach a release.
codesign --verify --deep --strict "$APP" || fail "code signature does not verify"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is not valid"
# No grep -q: it stops at the first match, otool then dies of SIGPIPE, and pipefail calls that a failure.
otool -l "$APP/Contents/MacOS/Tempo" | grep '@executable_path/../Frameworks' >/dev/null || fail "rpath missing"
[[ -x "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]] || fail "Sparkle.framework is incomplete"
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/Tempo")"
if [[ "$ARCHS" != "host" ]]; then
  [[ "$ARCHS_BUILT" == *arm64* && "$ARCHS_BUILT" == *x86_64* ]] || fail "not universal: $ARCHS_BUILT"
fi

# --norsrc keeps extended attributes out of the zip. macOS tags every file with com.apple.provenance,
# and --sequesterRsrc would store those as __MACOSX/._* entries: the zip must hold only Tempo.app/.
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "Built $APP $VERSION ($ARCHS_BUILT) and $ZIP"
