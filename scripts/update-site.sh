#!/bin/sh
# Updates the public BigEdit download page (in the maendeleo-site repo) from a
# GitHub release of this repo: downloads the notarized DMG under a versioned
# filename, drops the previous one, bumps the download link and version text,
# then commits and pushes so the host serves it on its next pull.
#
# Lives in this PRIVATE repo on purpose — the maendeleo-site repo is served
# publicly, so release tooling must not live there.
#
# Usage (run from anywhere):
#   scripts/update-site.sh             # use the latest BigEdit release
#   scripts/update-site.sh v0.1.7      # use a specific tag
#   NO_PUSH=1 scripts/update-site.sh   # do everything except git push
#   SITE_DIR=/path/to/maendeleo-site scripts/update-site.sh   # custom site path
#
# Requires the GitHub CLI (gh), authenticated with access to this repo.
set -e

REPO="rognlien/BigEdit"
BIGEDIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE_DIR="${SITE_DIR:-$(dirname "$BIGEDIT_DIR")/maendeleo-site}"

if [ ! -d "$SITE_DIR/bigedit" ]; then
    echo "error: site repo not found at $SITE_DIR (set SITE_DIR)" >&2
    exit 1
fi
cd "$SITE_DIR"

TAG="$1"
if [ -z "$TAG" ]; then
    TAG="$(gh release view --repo "$REPO" --json tagName --jq '.tagName')"
fi
VERSION="${TAG#v}"
DEST="bigedit/BigEdit-${VERSION}.dmg"
INDEX="bigedit/index.html"

echo "Updating $SITE_DIR to ${TAG} (version ${VERSION})"

gh release download "$TAG" --repo "$REPO" --pattern '*.dmg' --output "$DEST" --clobber

if command -v xcrun >/dev/null 2>&1; then
    xcrun stapler validate "$DEST" >/dev/null 2>&1 \
        && echo "notarization ticket: stapled" \
        || echo "warning: staple validation failed (is this a notarized DMG?)"
fi

# Remove any previously hosted versioned DMGs.
for dmg in bigedit/BigEdit-*.dmg; do
    if [ "$dmg" != "$DEST" ] && [ -f "$dmg" ]; then
        echo "removing old $dmg"
        git rm -q "$dmg" 2>/dev/null || rm -f "$dmg"
    fi
done

# Regenerate the Sparkle appcast: signs the DMG with the EdDSA private key from
# the login Keychain and writes bigedit/appcast.xml referencing the hosted URL.
GENERATE_APPCAST="$(find "$BIGEDIT_DIR/.build" -name generate_appcast -type f 2>/dev/null | head -1)"
if [ -z "$GENERATE_APPCAST" ]; then
    echo "error: generate_appcast not found — run 'swift build' in $BIGEDIT_DIR first" >&2
    exit 1
fi
# Regenerate from scratch so the appcast lists only the hosted DMG (we keep one
# versioned DMG; stale entries would point at deleted files).
rm -f bigedit/appcast.xml
"$GENERATE_APPCAST" bigedit --download-url-prefix "https://maendeleo.io/bigedit/"

# Point the download link at the new file and bump the version text.
sed -i '' -E "s#href=\"BigEdit-[^\"]*\.dmg\"#href=\"BigEdit-${VERSION}.dmg\"#" "$INDEX"
sed -i '' -E "s#Version [0-9]+\.[0-9]+\.[0-9]+[^ <]*#Version ${VERSION}#" "$INDEX"

git add "$DEST" "$INDEX" bigedit/appcast.xml
if git diff --cached --quiet; then
    echo "No changes — site already on ${VERSION}."
    exit 0
fi

git commit -q -m "Update BigEdit download to ${TAG}"
if [ -n "$NO_PUSH" ]; then
    echo "Committed (NO_PUSH set — not pushing)."
else
    git push origin main
    echo "Pushed. Live after the host's next pull."
fi
