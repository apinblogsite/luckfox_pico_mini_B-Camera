#!/bin/sh
# Tangkap gambar SIAP PAKAI lewat ISP (rkisp_mainpath), bukan Bayer mentah.
#
# ISP mengerjakan demosaic, black level, lens shading, dan denoise di silikon,
# lalu mengeluarkan YUV. Jauh lebih baik daripada merekonstruksi dari raw CIF.
#
# Pakai: sudo sh capture_isp.sh [width] [height] [output]
#   sudo sh capture_isp.sh                    -> 1280x720 ke /tmp/isp.yuv
#   sudo sh capture_isp.sh 2304 1296 /tmp/full
#
# Prasyarat: sudah menjalankan luckfox-camera-up.sh.
#
# Catatan: tanpa daemon rkaiq tidak ada auto-exposure maupun auto white
# balance. Eksposur diatur manual di sini; cast warna dikoreksi saat konversi
# dengan nv12_to_ppm.py ... awb

M=${M:-/dev/video11}          # rkisp_mainpath
SD=${SD:-/dev/v4l-subdev2}    # subdev sensor (punya kontrol exposure/gain)
W=${1:-1280}
H=${2:-720}
OUT=${3:-/tmp/isp}
FMT=${FMT:-NV12}
EXPO=${EXPO:-1200}
GAIN=${GAIN:-512}

command -v v4l2-ctl >/dev/null 2>&1 || { echo "butuh v4l-utils"; exit 1; }
[ -e "$M" ] || { echo "$M tidak ada -- jalankan luckfox-camera-up.sh dulu"; exit 1; }

echo "== eksposur sensor =="
v4l2-ctl -d "$SD" --set-ctrl=exposure=$EXPO,analogue_gain=$GAIN 2>/dev/null
v4l2-ctl -d "$SD" --get-ctrl=exposure,analogue_gain 2>/dev/null | sed 's/^/   /'

echo "== tangkap ${W}x${H} $FMT dari ISP =="
v4l2-ctl -d "$M" --set-fmt-video=width=$W,height=$H,pixelformat=$FMT >/dev/null 2>&1
v4l2-ctl -d "$M" --get-fmt-video 2>/dev/null | grep -E "Width|Pixel Format|Size Image" | sed 's/^/   /'

: > "$OUT.yuv"
v4l2-ctl -d "$M" --set-fmt-video=width=$W,height=$H,pixelformat=$FMT \
	--stream-mmap=2 --stream-count=1 --stream-to="$OUT.yuv" >/dev/null 2>&1

if [ ! -s "$OUT.yuv" ]; then
	echo "GAGAL. Kalau VIDIOC_REQBUFS 'Cannot allocate memory', buffer melebihi CMA."
	dmesg | grep -i cma_sg | tail -2
	exit 1
fi

echo "   $(stat -c%s "$OUT.yuv") byte -> $OUT.yuv"

if command -v python3 >/dev/null 2>&1; then
	DIR=$(cd "$(dirname "$0")" && pwd)
	python3 "$DIR/nv12_to_ppm.py" "$OUT.yuv" "$OUT.ppm" "$W" "$H" awb
	echo "   pratinjau: $OUT.ppm"
fi
