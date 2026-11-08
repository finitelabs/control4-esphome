#!/usr/bin/env bash
# Renders the DriverCentral banners, facts strip and listing photos at 2x with headless Chrome.
# Usage: render.sh [out-dir]   (default: next to each source)
# RENDER_TIMEOUT: the seconds one page may take before Chrome is stopped (default 60).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
limit=${RENDER_TIMEOUT:-60}
profile=$(mktemp -d)
trap 'command rm -rf "$profile"' EXIT

# stop <pid>: ends a hung Chrome and the helpers it started, which outlive it otherwise.
stop() {
	local pids
	pids="$(pgrep -P "$1" || true) $1"
	kill -TERM $pids 2>/dev/null || true
	sleep 2
	kill -KILL $pids 2>/dev/null || true
	wait "$1" 2>/dev/null || true
}

# top <png> <rows>: keeps the image's top pixel rows. A row of a non-interlaced PNG is filtered
# only against the rows above it, so the kept rows' bytes are copied unchanged.
top() {
	python3 - "$1" "$2" <<'PY'
import struct, sys, zlib

path, rows = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read()
chunks, pos = [], 8
while pos < len(data):
    size, kind = struct.unpack(">I4s", data[pos : pos + 8])
    chunks.append((kind, data[pos + 8 : pos + 8 + size]))
    pos += 12 + size
width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunks[0][1])
if interlace or rows > height:
    sys.exit(f"render.sh: {path} is interlaced or under {rows} rows tall")
stride = 1 + (width * {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color] * depth + 7) // 8
kept = zlib.decompress(b"".join(body for kind, body in chunks if kind == b"IDAT"))[: rows * stride]
parts, wrote = [data[:8]], False
for kind, body in chunks:
    if kind == b"IHDR":
        body = struct.pack(">II", width, rows) + body[8:]
    elif kind == b"IDAT":
        if wrote:
            continue
        body, wrote = zlib.compress(kept, 9), True
    parts.append(struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body)))
open(path, "wb").write(b"".join(parts))
PY
}

# shot <css-width,height> <output> <page> [rows]: rows keeps only the image's top pixel rows.
shot() {
	command mkdir -p "$(dirname "$out/$2")"
	command rm -f "$out/$2"
	# A page opened from disk loads the assets beside it only with file access allowed.
	"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --default-background-color=00000000 --window-size="$1" --allow-file-access-from-files \
		--virtual-time-budget=8000 --user-data-dir="$profile" --screenshot="$out/$2" "file://$here/$3" >/dev/null 2>&1 &
	local pid=$! waited=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$limit" ]; then
			stop "$pid"
			echo "render.sh: $2 took longer than ${limit}s, so Chrome was stopped; run render.sh again" >&2
			exit 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	# Chrome can exit non-zero after writing the file, so the file decides.
	wait "$pid" 2>/dev/null || true
	[ -s "$out/$2" ] || { echo "render.sh: $2 was not written" >&2; exit 1; }
	[ -z "${4:-}" ] || top "$out/$2" "$4"
	echo "$2"
}

shot 2048,424 banners/spotlight-4096x848.png banners/spotlight-4096x848.html
shot 1200,600 banners/launch-post-2400x1200.png banners/launch-post-2400x1200.html
# Chrome 157 hangs on a window under 88 px tall, so the 68 px strip renders in a taller one.
shot 1200,100 banners/facts-strip-2400x136.png banners/facts-strip-2400x136.html 136
while IFS='|' read -r name query || [ -n "$name" ]; do
	case "$name" in '' | '#'*) continue ;; esac
	shot 1000,1000 "photos/$name.png" "photos/frame.html?$query"
done <"$here/photos/photos.txt"
