#!/usr/bin/env bash
# Renders the DriverCentral banners, facts strip and listing photos at 2x with headless Chrome.
# Usage: render.sh [out-dir]   (default: next to each source)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
profile=$(mktemp -d)
trap 'command rm -rf "$profile"' EXIT

# shot <css-width,height> <output> <page>
shot() {
	command mkdir -p "$(dirname "$out/$2")"
	command rm -f "$out/$2"
	# A page opened from disk loads the assets beside it only with file access allowed.
	# Chrome can exit non-zero after writing the file, so the file decides.
	"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size="$1" --allow-file-access-from-files \
		--virtual-time-budget=8000 --user-data-dir="$profile" --screenshot="$out/$2" "file://$here/$3" >/dev/null 2>&1 || true
	[ -s "$out/$2" ] || { echo "render.sh: $2 was not written" >&2; exit 1; }
	echo "$2"
}

shot 2048,424 banners/spotlight-4096x848.png banners/spotlight-4096x848.html
shot 1200,600 banners/launch-post-2400x1200.png banners/launch-post-2400x1200.html
shot 1200,100 banners/facts-strip-2400x200.png banners/facts-strip-2400x200.html
while IFS='|' read -r name query || [ -n "$name" ]; do
	case "$name" in '' | '#'*) continue ;; esac
	shot 1000,1000 "photos/$name.png" "photos/frame.html?$query"
done <"$here/photos/photos.txt"
