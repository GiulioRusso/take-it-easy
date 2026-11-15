#!/bin/bash
# Everything for a release, in one go:
#   1. creates the self-signed signing certificate (first time only)
#   2. checks the repo is ready (clean, tag not used yet)
#   3. builds a universal Release signed with the certificate and zips it
#   4. creates the GitHub repo if there's no remote yet (asks first)
#   5. tags, pushes and publishes the GitHub release with the zip
#
# Usage:
#   scripts/release.sh 1.1              build and publish
#   scripts/release.sh 1.1 --no-publish only build the zip (steps 1-3)
#
# Environment (optional):
#   REPO_NAME    GitHub repo to create if missing (default: take-it-easy)
#   BACKUP_DIR   where the certificate backup goes (default: ~/TakeItEasy-signing, outside repo and iCloud)
#   P12_PASSWORD password for the certificate backup (default: generated and saved in BACKUP_DIR)
set -euo pipefail

VERSION=${1:?"usage: scripts/release.sh <version> [--no-publish], e.g. 1.1"}
PUBLISH=true
[ "${2:-}" = "--no-publish" ] && PUBLISH=false
TAG="v$VERSION"
IDENTITY="TakeItEasy Self-Signed"
KEYCHAIN=~/Library/Keychains/login.keychain-db
REPO_NAME=${REPO_NAME:-take-it-easy}
BACKUP_DIR=${BACKUP_DIR:-~/TakeItEasy-signing}
cd "$(dirname "$0")/.."

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. Certificate ---------------------------------------------------------------------------
# Same certificate on every release = same designated requirement = macOS keeps users' permissions.
step "Certificate"
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "«${IDENTITY}» found in the keychain."
else
    echo "Creating «${IDENTITY}» (valid 10 years)…"
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    P12="$BACKUP_DIR/signing.p12"
    if [ -z "${P12_PASSWORD:-}" ]; then
        P12_PASSWORD=$(openssl rand -base64 24)
        (umask 077 && echo "$P12_PASSWORD" > "$BACKUP_DIR/password.txt")
        echo "Backup password saved in $BACKUP_DIR/password.txt: move it to your password manager."
    fi
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    # -legacy: the macOS keychain can't read OpenSSL 3's default p12 encryption.
    LEGACY=$(openssl version | grep -q '^OpenSSL 3' && echo -legacy || true)
    openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
        -out "$P12" -passout pass:"$P12_PASSWORD"
    chmod 600 "$P12"
    security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    echo "Done. Backup: $P12 (keep it: losing it = users re-grant permissions once)."
fi

# --- 2. Checks --------------------------------------------------------------------------------
step "Checks"
if $PUBLISH; then
    command -v gh >/dev/null || fail "GitHub CLI missing: brew install gh"
    gh auth status >/dev/null 2>&1 || fail "not logged in to GitHub: gh auth login"
    [ -z "$(git status --porcelain)" ] || fail "uncommitted changes: commit them first (git status)"
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG exists already: pick a new version"
fi
echo "OK."

# --- 3. Build, sign, zip ----------------------------------------------------------------------
step "Build $VERSION"
OUT=build/release
# Build outside the repo: iCloud Drive tags files with extended attributes that codesign rejects.
DD="${TMPDIR:-/tmp}/takeiteasy-release"
rm -rf "$OUT" "$DD"
mkdir -p "$OUT"
xcodebuild -project TakeItEasy.xcodeproj -scheme TakeItEasy -configuration Release -derivedDataPath "$DD" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build > "$OUT/build.log" 2>&1 || { grep -E "error" "$OUT/build.log" | head -20; fail "build failed (full log: $OUT/build.log)"; }
APP="$DD/Build/Products/Release/TakeItEasy.app"
codesign --verify --strict --deep "$APP"
# The requirement macOS stores with the permissions: must name the certificate, not a per-build hash.
codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf" || fail "not signed with the certificate: permissions would reset"
ZIP="$OUT/TakeItEasy-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP ($(du -h "$ZIP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/TakeItEasy"))"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
$PUBLISH || { echo; echo "Built only (--no-publish)."; exit 0; }

# --- 4. GitHub repo ---------------------------------------------------------------------------
step "GitHub"
if ! git remote get-url origin >/dev/null 2>&1; then
    echo "No remote yet. Users can only download releases from a PUBLIC repo."
    read -r -p "Create the public repo «${REPO_NAME}» on your GitHub account and push? [y/N] " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || fail "cancelled: nothing published"
    gh repo create "$REPO_NAME" --public --source . --push
else
    git push origin HEAD
fi

# --- 5. Tag and release -----------------------------------------------------------------------
step "Release $TAG"
git tag -a "$TAG" -m "take-it-easy $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "take-it-easy $VERSION" --generate-notes
echo
echo "Published: $(gh release view "$TAG" --json url -q .url)"
