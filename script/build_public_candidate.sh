#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d /private/tmp/nyaeh-public-build.XXXXXX)"
DEST="${1:-/private/tmp/NyaEH-Public-1.6.0-160.app.zip}"
VERSION=1.6.0
BUILD=160
cleanup() {
  result=$?
  if [[ "$result" != 0 && "${NYAEH_KEEP_FAILED_BUILD:-0}" == 1 ]]; then
    printf 'Quarantined failed build: %s\n' "$WORK" >&2
  else
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT
if [[ "$DEST" != /* || -e "$DEST" || -L "$DEST" ]]; then
  echo "Choose an absolute output path that does not exist." >&2
  exit 2
fi
PUBLIC_KEY="${NYAEH_SPARKLE_PUBLIC_KEY:?Set NYAEH_SPARKLE_PUBLIC_KEY from the independent public-channel signer.}"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "Invalid Sparkle public key." >&2; exit 2; }
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo "Build only from a committed, clean snapshot." >&2; exit 2; }
mkdir "$WORK/source"
git -C "$ROOT" archive HEAD | tar -xf - -C "$WORK/source"
PROJECT="$WORK/source/Packaging/NyaEH/NyaEH.xcodeproj"
MAP="$WORK/source=/nyaeh/source"
TMP_MAP="$WORK=/nyaeh/build"
XCODE_ALIAS_MAP="${WORK#/private}=/nyaeh/build"
LOG="$WORK/build.log"
if ! xcodebuild -project "$PROJECT" -scheme NyaEH -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$WORK/DerivedData" \
  -disableAutomaticPackageResolution build \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  NYAEH_SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
  "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $MAP -debug-prefix-map $MAP -file-prefix-map $TMP_MAP -debug-prefix-map $TMP_MAP -file-prefix-map $XCODE_ALIAS_MAP -debug-prefix-map $XCODE_ALIAS_MAP" \
  "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$MAP -ffile-prefix-map=$TMP_MAP -ffile-prefix-map=$XCODE_ALIAS_MAP" \
  > "$LOG" 2>&1; then
  tail -70 "$LOG" >&2
  exit 1
fi
APP="$WORK/DerivedData/Build/Products/Release/NyaEH.app"
INFO="$APP/Contents/Info.plist"
MAIN="$APP/Contents/MacOS/NyaEH"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
[[ "$(plist CFBundleShortVersionString "$INFO")" == "$VERSION" ]]
[[ "$(plist CFBundleVersion "$INFO")" == "$BUILD" ]]
[[ "$(plist CFBundleIdentifier "$INFO")" == com.gazelee.NyaEH ]]
[[ "$(plist SUPublicEDKey "$INFO")" == "$PUBLIC_KEY" ]]
[[ "$(lipo -archs "$MAIN")" == arm64 ]]
for key in SURequireSignedFeed SUEnableInstallerLauncherService SUVerifyUpdateBeforeExtraction; do
  [[ "$(plist "$key" "$INFO")" == true ]]
done
bash "$ROOT/script/check_app_icon.sh" "$APP"

# Keep dSYMs outside the bundle. Local linker symbols can also retain absolute paths.
codesign --remove-signature "$MAIN" 2>/dev/null || true
xcrun strip -S -x "$MAIN"
cp -R "$ROOT/Licenses" "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/NyaEH-MIT.txt"
cp "$ROOT/Sources/CSQLiteVec/LICENSE-MIT" "$APP/Contents/Resources/Licenses/sqlite-vec-MIT.txt"
cp "$ROOT/Sources/CSQLiteVec/LICENSE-APACHE" "$APP/Contents/Resources/Licenses/sqlite-vec-APACHE.txt"

ENTITLEMENTS="$WORK/entitlements.plist"
python3 - "$ENTITLEMENTS" <<'PYTHON'
import plistlib
import sys
with open(sys.argv[1], "wb") as out:
    plistlib.dump({
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.network.client": True,
        "com.apple.security.network.server": True,
        "com.apple.security.temporary-exception.mach-lookup.global-name": [
            "com.gazelee.NyaEH-spks", "com.gazelee.NyaEH-spki"
        ],
    }, out)
PYTHON
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > "$WORK/signed.entitlements"
for key in app-sandbox files.user-selected.read-write network.client network.server; do
  [[ "$(plist "com.apple.security.$key" "$WORK/signed.entitlements")" == true ]]
done
if grep -q 'com.apple.security.get-task-allow' "$WORK/signed.entitlements"; then
  echo "Candidate includes a debugging entitlement." >&2
  exit 1
fi
ditto -c -k --keepParent "$APP" "$WORK/candidate.zip"
python3 "$ROOT/script/audit_public_snapshot.py" --zip "$WORK/candidate.zip" \
  --reject-prefix "$ROOT" --reject-prefix "$WORK" --reject-prefix "${WORK#/private}"
cp -n "$WORK/candidate.zip" "$DEST"
cmp "$WORK/candidate.zip" "$DEST"
shasum -a 256 "$DEST"
