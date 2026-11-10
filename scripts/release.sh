#!/usr/bin/env bash
# Builds, zips and publishes a GitHub release. The install guide (docs/INSTALL.md,
# including the xattr quarantine step) is always appended to the notes.
#   scripts/release.sh 0.1.5 notes.md
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> <notes.md>}"
NOTES="${2:?usage: scripts/release.sh <version> <notes.md>}"
TAG="v$VERSION"
ZIP="build/OpenHoy-$VERSION-macOS.zip"

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "Resources/Info.plist says $PLIST_VERSION, not $VERSION — bump it first." >&2
  exit 1
fi

# Public builds are ad-hoc signed unless SIGN_IDENTITY says otherwise: a personal
# Apple Development certificate would put its owner's name and email in the download.
SIGN_IDENTITY="${SIGN_IDENTITY:--}" scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/OpenHoy.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

BODY="$(mktemp)"
{
  cat "$NOTES"
  printf '\n\n'
  sed "s/<version>/$VERSION/g" docs/INSTALL.md
  printf '\nSHA-256: `%s`\n' "$SHA"
} > "$BODY"

gh release create "$TAG" "$ZIP" --target main --title "OpenHoy $VERSION" --notes-file "$BODY"
