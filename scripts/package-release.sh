#!/bin/bash
# Package an existing universal Release build; never build, install, or launch it.
# Requires macOS/Xcode tools and jq; --notarize additionally requires asc auth.
# Usage: scripts/package-release.sh --identity 'Developer ID Application: NAME (TEAM)' [--notarize] [--app PATH]
# Signing/notarization evidence stays in ignored .build/Distribution/Sniplet-VERSION/.
# Two Apple submissions let both the ZIP's app and the DMG carry offline tickets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$ROOT/.build/ReleaseDerivedData/Build/Products/Release/Sniplet.app"
IDENTITY=""
NOTARIZE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="${2:?Missing signing identity}"; shift 2 ;;
        --app) SOURCE="${2:?Missing app path}"; shift 2 ;;
        --notarize) NOTARIZE=1; shift ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$IDENTITY" == 'Developer ID Application: '* ]] || { echo 'A Developer ID Application --identity is required.' >&2; exit 2; }
for tool in codesign lipo plutil ditto hdiutil shasum jq; do
    command -v "$tool" >/dev/null || { printf 'Missing required tool: %s\n' "$tool" >&2; exit 2; }
done
if [[ "$NOTARIZE" == 1 ]]; then
    command -v asc >/dev/null || { echo 'Missing asc; configure App Store Connect keychain authentication first.' >&2; exit 2; }
fi
PLIST="$SOURCE/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && "$BUILD" =~ ^[0-9]+$ ]] || { echo 'Invalid version/build in source app.' >&2; exit 2; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == com.elazer.Sniplet ]] || { echo 'Source is not Sniplet.' >&2; exit 2; }
OUTPUT="$ROOT/.build/Distribution/Sniplet-$VERSION"
[[ ! -e "$OUTPUT" ]] || { printf 'Refusing to overwrite existing distribution: %s\n' "$OUTPUT" >&2; exit 2; }
mkdir -p "$OUTPUT/evidence" "$OUTPUT/work"
APP="$OUTPUT/Sniplet.app"
ZIP="$OUTPUT/Sniplet-$VERSION-universal.zip"
DMG="$OUTPUT/Sniplet-$VERSION-universal.dmg"
WORK="$OUTPUT/work"
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$WORK/mount" -quiet || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
cat > "$WORK/expected-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
</dict></plist>
PLIST
codesign -d --verbose=4 "$SOURCE" 2> "$OUTPUT/evidence/source-signature.txt"
# Preserve the app's identity/team without modifying the original or installed app.
/usr/bin/grep -Fx "Authority=$IDENTITY" "$OUTPUT/evidence/source-signature.txt" >/dev/null || { echo 'Requested identity differs from source Developer ID.' >&2; exit 2; }
ditto "$SOURCE" "$APP"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$WORK/expected-entitlements.plist" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tee "$OUTPUT/evidence/app-signature-verification.txt"
codesign -d --verbose=4 "$APP" 2> "$OUTPUT/evidence/app-signature.txt"
/usr/bin/grep -E '^Timestamp=' "$OUTPUT/evidence/app-signature.txt" >/dev/null
/usr/bin/grep -E '^CodeDirectory .*flags=.*\(runtime\)' "$OUTPUT/evidence/app-signature.txt" >/dev/null
codesign -d --entitlements - --xml "$APP" > "$OUTPUT/evidence/entitlements.plist" 2> "$OUTPUT/evidence/entitlements-command.txt"
plutil -convert json -o "$WORK/entitlements.json" "$OUTPUT/evidence/entitlements.plist"
jq -e '. == {"com.apple.security.app-sandbox": true, "com.apple.security.files.user-selected.read-write": true}' "$WORK/entitlements.json" >/dev/null
lipo -archs "$APP/Contents/MacOS/Sniplet" | tee "$OUTPUT/evidence/architectures.txt"
case "$(cat "$OUTPUT/evidence/architectures.txt")" in
    'arm64 x86_64'|'x86_64 arm64') ;;
    *) echo 'Release must contain exactly arm64 and x86_64.' >&2; exit 2 ;;
esac
printf 'Version: %s\nBuild: %s\nMinimum macOS: %s\n' "$VERSION" "$BUILD" \
    "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" > "$OUTPUT/evidence/version.txt"

submit() {
    local file="$1" label="$2"
    # asc owns the supported wait loop. Never manually resubmit or poll on failure.
    if ! asc notarization submit --file "$file" --wait --poll-interval 30s --timeout 1h --output json \
        > "$OUTPUT/evidence/$label-notarization.json" 2> "$OUTPUT/evidence/$label-notarization.log"; then
        printf 'Apple submission failed; inspect %s/evidence/%s-notarization.log\n' "$OUTPUT" "$label" >&2
        return 1
    fi
    cat "$OUTPUT/evidence/$label-notarization.json"
    # Require exactly one returned status and require Accepted, independent of JSON wrapping.
    jq -e '[.. | objects | .status? // empty] == ["Accepted"]' "$OUTPUT/evidence/$label-notarization.json" >/dev/null
}

APP_ACCEPTED=0
DMG_ACCEPTED=0
if [[ "$NOTARIZE" == 1 ]]; then
    ditto -c -k --keepParent "$APP" "$WORK/notarization.zip"
    if submit "$WORK/notarization.zip" app; then
        xcrun stapler staple "$APP" 2>&1 | tee "$OUTPUT/evidence/app-staple.txt"
        xcrun stapler validate "$APP" 2>&1 | tee "$OUTPUT/evidence/app-staple-validation.txt"
        spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee "$OUTPUT/evidence/app-gatekeeper.txt"
        APP_ACCEPTED=1
    fi
fi
# Re-create ZIP after stapling so extraction retains the offline app ticket.
ditto -c -k --keepParent "$APP" "$ZIP"
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Sniplet.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname Sniplet -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG" 2>&1 | tee "$OUTPUT/evidence/dmg-signature-verification.txt"
codesign -d --verbose=4 "$DMG" 2> "$OUTPUT/evidence/dmg-signature.txt"
if [[ "$APP_ACCEPTED" == 1 ]]; then
    if submit "$DMG" dmg; then
        xcrun stapler staple "$DMG" 2>&1 | tee "$OUTPUT/evidence/dmg-staple.txt"
        xcrun stapler validate "$DMG" 2>&1 | tee "$OUTPUT/evidence/dmg-staple-validation.txt"
        spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1 | tee "$OUTPUT/evidence/dmg-gatekeeper.txt"
        DMG_ACCEPTED=1
    fi
fi
# Mount without Finder or a window; check the actual public-download contents.
mkdir "$WORK/mount"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$WORK/mount" > "$OUTPUT/evidence/dmg-mount.txt"
MOUNTED=1
[[ "$(readlink "$WORK/mount/Applications")" == /Applications ]]
codesign --verify --deep --strict "$WORK/mount/Sniplet.app"
if [[ "$DMG_ACCEPTED" == 1 ]]; then
    xcrun stapler validate "$WORK/mount/Sniplet.app" 2>&1 | tee "$OUTPUT/evidence/dmg-contained-app-staple.txt"
fi
hdiutil detach "$WORK/mount" -quiet
MOUNTED=0
mkdir "$WORK/zip"
ditto -x -k "$ZIP" "$WORK/zip"
codesign --verify --deep --strict "$WORK/zip/Sniplet.app"
if [[ "$APP_ACCEPTED" == 1 ]]; then
    xcrun stapler validate "$WORK/zip/Sniplet.app" 2>&1 | tee "$OUTPUT/evidence/zip-contained-app-staple.txt"
fi
(cd "$OUTPUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS)
cat "$OUTPUT/SHA256SUMS"
if [[ "$APP_ACCEPTED" == 1 && "$DMG_ACCEPTED" == 1 ]]; then
    echo 'App and DMG: Accepted, stapled, validated, and Gatekeeper accepted.' | tee "$OUTPUT/evidence/distribution-status.txt"
else
    echo 'SIGNED ONLY: notarization/Gatekeeper distribution acceptance is NOT established for both artifacts.' | tee "$OUTPUT/evidence/distribution-status.txt"
    [[ "$NOTARIZE" == 0 ]] || exit 1
fi
printf 'Distribution: %s\n' "$OUTPUT"
