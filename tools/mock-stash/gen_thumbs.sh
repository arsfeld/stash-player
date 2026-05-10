#!/usr/bin/env bash
# Regenerate the SFW placeholder thumbnails served by server.py.
#
# The 12 .jpg files under thumbs/ are checked in, so you only need to
# run this if you change the scene list (server.py SCENES) or want to
# tweak the artwork.
#
# Requires: ffmpeg, fontconfig (fc-match).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/thumbs"
mkdir -p "$OUT"

FONT="$(fc-match -f '%{file}' sans 2>/dev/null || true)"
if [ -z "$FONT" ] || [ ! -f "$FONT" ]; then
  echo "could not resolve a sans font via fc-match" >&2
  exit 1
fi

# id|title|hex_top|hex_bottom — keep in sync with SCENES in server.py.
SCENES=(
  "1001|Aurora Over Tromso|0c2a4a|3b6f9b"
  "1002|Sunrise in Hokkaido|f4a261|e76f51"
  "1003|Rooftop Jazz Midnight|1d1d27|6a4c93"
  "1004|Trinity College Library|3e2f1c|b08968"
  "1005|Volcanic Iceland Coast|2b2d42|8d99ae"
  "1006|Paris in the Rain|2e3a59|7d8597"
  "1007|Kyoto Cherry Blossoms|3a0a3a|f4acb7"
  "1008|Sailing the Greek Isles|0a558c|4cc9f0"
  "1009|Snow Trails in the Alps|2c3e50|ecf0f1"
  "1010|Sahara Stargazing|0b132b|3a506b"
  "1011|Fjord Kayak Day|264653|2a9d8f"
  "1012|Lighthouse on the Cape|1b1b3a|e63946"
)

for s in "${SCENES[@]}"; do
  IFS='|' read -r id title top bot <<< "$s"
  ffmpeg -loglevel error -y \
    -f lavfi -i "color=c=0x${top}:s=640x360,format=rgba" \
    -f lavfi -i "color=c=0x${bot}:s=640x360,format=rgba" \
    -filter_complex "
      [1]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*Y/H'[bot];
      [0][bot]overlay=format=auto[bg];
      [bg]drawbox=x=0:y=240:w=640:h=120:color=black@0.45:t=fill[box];
      [box]drawtext=fontfile='${FONT}':text='${title}':fontcolor=white:fontsize=30:x=24:y=265,
           drawtext=fontfile='${FONT}':text='Scene #${id}':fontcolor=#cfcfcf:fontsize=18:x=24:y=310
    " \
    -frames:v 1 "$OUT/${id}.jpg"
  echo "made $OUT/${id}.jpg"
done
