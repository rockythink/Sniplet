#!/bin/sh
# Render website/og/og.html to website/public/og.png (1200 × 630) with headless Chrome.
# Fonts come from website/node_modules, so run `npm --prefix website ci` first.
# Usage: scripts/render-og.sh [output.png]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/website/public/og.png"}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
port=${OG_PORT:-4399}
[ -d "$root/website/node_modules/@fontsource-variable" ] || { echo "Run: npm --prefix website ci" >&2; exit 1; }
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$root/website" >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null' EXIT
sleep 1
profile=$(mktemp -d)
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --user-data-dir="$profile" --window-size=1200,630 --virtual-time-budget=4000 \
  --screenshot="$out" "http://127.0.0.1:$port/og/og.html" >/dev/null 2>&1
rm -rf "$profile"
echo "Wrote $out"
