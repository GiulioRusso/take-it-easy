#!/bin/bash
# Builds a Release signed with the self-signed certificate and zips it for a GitHub release.
# Usage: scripts/release.sh 1.0
set -euo pipefail
VERSION=${1:?usage: scripts/release.sh <version>, e.g. 1.0}
IDENTITY="TakeItEasy Self-Signed"
cd "$(dirname "$0")/.."
OUT=build/release
# Build outside the repo: iCloud Drive tags files with extended attributes that codesign rejects.
DD="${TMPDIR:-/tmp}/takeiteasy-release"
rm -rf "$OUT" "$DD"
mkdir -p "$OUT"
xcodebuild -project TakeItEasy.xcodeproj -scheme TakeItEasy -configuration Release -derivedDataPath "$DD" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build | grep -E "error|warning: |BUILD" || true
APP="$DD/Build/Products/Release/TakeItEasy.app"
codesign --verify --strict --deep "$APP"
# The requirement macOS stores with the permissions: must name the certificate, not a per-build hash (cdhash).
REQ=$(codesign -d -r- "$APP" 2>&1 | grep designated)
echo "$REQ"
echo "$REQ" | grep -q "certificate leaf" || { echo "Not signed with the certificate: permissions would reset."; exit 1; }
ZIP="$OUT/TakeItEasy-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo
echo "Publish with:  gh release create v$VERSION \"$ZIP\" --title \"take-it-easy $VERSION\" --generate-notes"
