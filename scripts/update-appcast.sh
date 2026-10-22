#!/bin/bash
# Write website/public/appcast.xml for a notarized release in .build/Distribution/Sniplet-VERSION.
# The ZIP is signed with Sparkle's EdDSA key from the maintainer's login Keychain (sign_update);
# the private key is never read or printed here. Deploy the website afterwards.
# Usage: scripts/update-appcast.sh --version 0.9.0 --notes path/to/release-notes.md
# Only the notes' "## 更新" section is shown in Sparkle's update window.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION=""
NOTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?Missing version}"; shift 2 ;;
        --notes) NOTES="${2:?Missing notes file}"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo 'A valid --version is required.' >&2; exit 2; }
[[ -f "$NOTES" ]] || { echo 'A --notes markdown file is required.' >&2; exit 2; }
DIST="$ROOT/.build/Distribution/Sniplet-$VERSION"
ZIP="$DIST/Sniplet-$VERSION-universal.zip"
APP="$DIST/Sniplet.app"
[[ -f "$ZIP" && -d "$APP" ]] || { printf 'Missing packaged release in %s\n' "$DIST" >&2; exit 2; }
grep -qx 'App and DMG: Accepted, stapled, validated, and Gatekeeper accepted.' "$DIST/evidence/distribution-status.txt" 2>/dev/null \
    || { echo 'Release is not notarized; refusing to publish it to the appcast.' >&2; exit 2; }
SIGN_UPDATE=$(find "$ROOT/.build" -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)
[[ -x "$SIGN_UPDATE" ]] || { echo 'Missing Sparkle sign_update; resolve packages with xcodebuild first.' >&2; exit 2; }

BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$SHORT" == "$VERSION" ]] || { echo 'Packaged app version differs from --version.' >&2; exit 2; }
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE=$("$SIGN_UPDATE" "$ZIP")
[[ "$SIGNATURE" == sparkle:edSignature=*length=* ]] || { echo 'sign_update did not return a signature.' >&2; exit 2; }

python3 - "$VERSION" "$BUILD" "$MINIMUM" "$SIGNATURE" "$NOTES" "$ROOT/website/public/appcast.xml" <<'PY'
import html, re, sys
from email.utils import formatdate
version, build, minimum, signature, notes_path, out = sys.argv[1:]
notes = open(notes_path, encoding="utf-8").read()
section = re.search(r"^## 更新\n(.*?)(?=^## |\Z)", notes, re.S | re.M)
lines = section.group(1).splitlines() if section else []
parts, depth = [], 0
for line in lines:
    match = re.match(r"^(\s*)- (.*)$", line)
    if not match:
        continue
    level = 1 + len(match.group(1)) // 2
    while depth < level:
        parts.append("<ul>"); depth += 1
    while depth > level:
        parts.append("</ul>"); depth -= 1
    parts.append(f"<li>{html.escape(match.group(2))}</li>")
parts.extend(["</ul>"] * depth)
url = f"https://github.com/rockythink/Sniplet/releases/download/v{version}/Sniplet-{version}-universal.zip"
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sniplet</title>
    <link>https://sniplet.elazer.wang/appcast.xml</link>
    <language>zh-CN</language>
    <item>
      <title>Sniplet {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <description><![CDATA[{''.join(parts)}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>
  </channel>
</rss>
"""
open(out, "w", encoding="utf-8").write(xml)
print(out)
PY
