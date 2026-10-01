#!/bin/sh
# Installs or updates Tempo for the current user. No admin rights needed.
#   curl -fsSL https://raw.githubusercontent.com/NoeFabris/tempo/main/install.sh | sh
# curl downloads carry no quarantine flag, so macOS shows no Gatekeeper dialog for this app.
set -eu

REPO="NoeFabris/tempo"
ZIP_URL="${TEMPO_ZIP_URL:-https://github.com/$REPO/releases/latest/download/Tempo.zip}"
APP_DIR="${TEMPO_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Tempo.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "install: $*" >&2; exit 1; }

echo "Downloading the latest Tempo..."
curl -fsSL -o "$TMP/Tempo.zip" "$ZIP_URL" || fail "download failed ($ZIP_URL)"
ditto -x -k "$TMP/Tempo.zip" "$TMP/x" || fail "could not extract the archive"
[ -x "$TMP/x/Tempo.app/Contents/MacOS/Tempo" ] || fail "the archive does not contain Tempo.app"
codesign --verify --deep --strict "$TMP/x/Tempo.app" || fail "the app is damaged (signature check failed)"
NEW_VERSION="$(defaults read "$TMP/x/Tempo.app/Contents/Info.plist" CFBundleShortVersionString)"

if pgrep -xq Tempo; then
  echo "Quitting the running Tempo..."
  # The pgrep guard matters: without it, AppleScript would launch Tempo in order to quit it.
  osascript -e 'tell application id "app.tempo.menubar" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq Tempo && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
  if pgrep -xq Tempo; then pkill -x Tempo || true; sleep 1; fi
fi

mkdir -p "$APP_DIR"
rm -rf "$APP"
ditto "$TMP/x/Tempo.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [ -d "/Applications/Tempo.app" ] && [ "$APP" != "/Applications/Tempo.app" ]; then
  echo "Note: an older copy exists at /Applications/Tempo.app. Delete it to avoid two copies."
fi

open "$APP"
echo "Installed Tempo $NEW_VERSION to $APP_DIR"
