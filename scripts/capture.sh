#!/bin/sh
# Tangkap satu frame mentah dari sensor CSI dan konversi ke PGM.
#
# Pakai: sudo sh capture.sh [width] [height] [output-prefix]
#   sudo sh capture.sh                 -> 640x480 ke /tmp/shot
#   sudo sh capture.sh 320 240 /tmp/kecil
#
# Batas resolusi ditentukan CMA (lihat README):
#   CMA 1 MB  (bawaan) -> maksimal 640x480
#   CMA 16 MB          -> 2304x1296 (resolusi penuh SC3336)

V=${V:-/dev/video0}
W=${1:-640}
H=${2:-480}
OUT=${3:-/tmp/shot}
FMT=${FMT:-BG10}

command -v v4l2-ctl >/dev/null 2>&1 || { echo "butuh v4l-utils: apt install v4l-utils"; exit 1; }
[ -e "$V" ] || { echo "$V tidak ada -- jalankan luckfox-camera-up.sh dulu"; exit 1; }

echo "== set format ${W}x${H} $FMT =="
v4l2-ctl -d "$V" --set-fmt-video=width=$W,height=$H,pixelformat=$FMT >/dev/null 2>&1
STRIDE=$(v4l2-ctl -d "$V" --get-fmt-video 2>/dev/null | awk '/Bytes per Line/{print $5}')
SIZE=$(v4l2-ctl -d "$V" --get-fmt-video 2>/dev/null | awk '/Size Image/{print $4}')
echo "   stride=$STRIDE  size=$SIZE  (2 buffer = $((SIZE * 2)) byte)"

echo "== tangkap =="
rm -f "$OUT.raw"
if ! v4l2-ctl -d "$V" --set-fmt-video=width=$W,height=$H,pixelformat=$FMT \
	--stream-mmap=2 --stream-count=1 --stream-to="$OUT.raw" 2>&1 | grep -v '^$'; then
	:
fi

if [ ! -s "$OUT.raw" ]; then
	echo "GAGAL. Kalau pesannya VIDIOC_REQBUFS 'Cannot allocate memory',"
	echo "buffer melebihi CMA. Turunkan resolusi atau naikkan rk_dma_heap_cma."
	dmesg | grep -i 'cma_sg' | tail -2
	exit 1
fi

echo "   $(stat -c%s "$OUT.raw") byte -> $OUT.raw"

if command -v python3 >/dev/null 2>&1; then
	DIR=$(cd "$(dirname "$0")" && pwd)
	python3 "$DIR/raw10_to_pgm.py" "$OUT.raw" "$OUT.pgm" "$W" "$H" "$STRIDE"
	echo "   pratinjau: $OUT.pgm"
fi
