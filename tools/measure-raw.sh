#!/usr/bin/env bash
# Capture raw Bayer frames from the imx471 and report the sensor's raw channel ratios,
# for identifying the fitted camera module against Intel's factory calibration blobs.
# Usage: measure-raw.sh <tag> [--black R,Gr,Gb,B] [--window x0,y0,w,h]
#
# Fångar rå Bayer-data från imx471 och rapporterar sensorns råa kanalförhållanden.
#
# Syfte: fastställa kameramodulens identitet mot Intels fabriksblobbar (AIQB), som
# innehåller per-modul vitpunkter (r_per_g, b_per_g) per ljuskälla. Skillnaden mellan
# moduler är ~8 %, alltså mätbar.
#
# Kör två strömmar (rå + synlig) med flit: med bara rå-strömmen får soft-ISP:ns AGC inga
# statistik och exponeringen står kvar på max, vilket klipper ett vitt mål direkt.
# LIBCAMERA_PIPELINES_MATCH_LIST=simple är OBLIGATORISK när en USB-kamera är inkopplad,
# annars mäts tyst på fel sensor.
#
# Användning:  measure-raw.sh <tagg> [--black R,Gr,Gb,B]
set -uo pipefail
TAG="${1:-mät}"; shift || true
DIR="/tmp/raw-$TAG"
rm -rf "$DIR"; mkdir -p "$DIR"

LIBCAMERA_PIPELINES_MATCH_LIST=simple timeout 60 cam -c1 --capture=70 \
  --stream role=raw --file="$DIR/r#.bin" \
  --stream role=viewfinder --file="$DIR/v#.bin" >"$DIR/log" 2>&1

# båda --file kollapsar till samma prefix; rå-strömmen är stream0 (4,2 MB)
last=$(ls "$DIR"/*stream0-*.bin 2>/dev/null | tail -1)
[ -z "$last" ] && { echo "$TAG: ingen rå bild - se $DIR/log"; exit 1; }

echo "== $TAG =="
command grep -oE 'configuring streams.*' "$DIR/log" | head -1 | sed 's/^/  /'
echo "  exponering nu: $(v4l2-ctl -d /dev/v4l-subdev4 -C exposure 2>/dev/null | cut -d: -f2)"
python3 "$(dirname "$0")"/raw-whitepoint.py "$last" "$@"
