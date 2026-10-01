#!/bin/bash
# Publishes one version: builds, signs the archive with the Sparkle EdDSA key, extends the appcast
# and creates the GitHub release. Same script on the maintainer's Mac and in the Release workflow.
#   VERSION=1.2.0            required (the workflow derives it from the tag v1.2.0)
#   REPO=owner/repo          GitHub repository
#   SPARKLE_PRIVATE_KEY=…    the private key; when unset, generate_appcast reads the login Keychain
#   DRY_RUN=1                everything except the GitHub release; leaves feed/ for inspection
#   PREVIOUS_APPCAST_URL=…   where the published feed is (tests point it at a local file)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-NoeFabris/tempo}"
VERSION="${VERSION:-${GITHUB_REF_NAME:-}}"
VERSION="${VERSION#v}"
PREVIOUS_APPCAST_URL="${PREVIOUS_APPCAST_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}"
fail() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.0, got '${VERSION:-<empty>}'"
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG does not exist; run: git tag $TAG"
[[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "tag $TAG does not point at HEAD"

rm -rf feed && mkdir -p feed
# The published feed (none before the first release). generate_appcast appends the new item to it and
# keeps the older items, whose enclosures point at their own tags.
curl -fsSL -o feed/appcast.xml "$PREVIOUS_APPCAST_URL" 2>/dev/null || rm -f feed/appcast.xml
if [[ -f feed/appcast.xml ]]; then
  # generate_appcast writes the version as an element: <sparkle:version>1.2.0</sparkle:version>
  NEWEST="$( { grep -o '<sparkle:version>[^<]*</sparkle:version>' feed/appcast.xml || true; } | sed -e 's/<[^>]*>//g' | sort -V | tail -1)"
  HIGHEST="$(printf '%s\n%s\n' "$NEWEST" "$VERSION" | sort -V | tail -1)"
  [[ "$HIGHEST" == "$VERSION" && "$NEWEST" != "$VERSION" ]] || fail "$VERSION is not newer than the published $NEWEST"
fi

VERSION="$VERSION" REPO="$REPO" scripts/build-app.sh
cp dist/Tempo.zip feed/Tempo.zip

# Release notes: one line per commit since the previous tag. The same basename as the archive makes
# generate_appcast attach them to the item (markdown needs Sparkle 2.9+, which the app embeds).
PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
{
  echo "## Tempo $VERSION"
  echo
  if [[ -n "$PREV_TAG" ]]; then git log --format='- %s' "$PREV_TAG..HEAD"; else git log --format='- %s'; fi
} > feed/Tempo.md

GEN="$(find .build/artifacts -type f -name generate_appcast | head -1)"
[[ -n "$GEN" ]] || fail "generate_appcast not found under .build/artifacts (run swift build)"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GEN" --ed-key-file - --download-url-prefix "$PREFIX" \
    --link "https://github.com/$REPO" --embed-release-notes feed
else
  "$GEN" --download-url-prefix "$PREFIX" --link "https://github.com/$REPO" --embed-release-notes feed
fi

grep -q "<sparkle:version>$VERSION</sparkle:version>" feed/appcast.xml || fail "appcast has no item for $VERSION"
grep -q "releases/download/$TAG/Tempo.zip" feed/appcast.xml || fail "appcast enclosure URL is wrong"
# generate_appcast exits 0 and leaves the new item unsigned when SUPublicEDKey does not match the key,
# so check the new item's enclosure, not any older signed item.
grep -q "releases/download/$TAG/Tempo.zip\"[^>]*sparkle:edSignature=\"" feed/appcast.xml \
  || fail "the new appcast item has no EdDSA signature (is SUPublicEDKey the public half of the signing key?)"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "Dry run: feed/ is ready, no release created"
  exit 0
fi
gh release create "$TAG" feed/Tempo.zip feed/appcast.xml --repo "$REPO" --title "Tempo $VERSION" \
  --notes-file feed/Tempo.md --verify-tag
echo "Released https://github.com/$REPO/releases/tag/$TAG"
