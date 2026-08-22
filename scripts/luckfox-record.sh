#!/bin/sh
# Rekam video H.264/H.265/MJPEG dari kamera CSI ke berkas.
#
# Pakai:
#   sudo sh luckfox-record.sh                          # 1280x720, 300 frame (~10 dtk)
#   sudo sh luckfox-record.sh 1920 1080 90
#   CODEC=h265 sudo sh luckfox-record.sh 1280 720 150
#   AIQ=0 sudo sh luckfox-record.sh                    # tanpa 3A, eksposur manual
#
# Prasyarat:
#   1. luckfox-venc-up.sh sudah dijalankan (memuat kamera + encoder + rockit)
#   2. rkrun terpasang (runtime uClibc) -- lihat README repo Wiki, Bagian 17
#
# ---------------------------------------------------------------------------
# KENAPA 3A (rkaiq) DIJALANKAN LEWAT systemd-run
#
# rkaiq_3A_server harus hidup selama perekaman berlangsung. Menjalankannya
# sebagai proses latar biasa dari sesi SSH TIDAK bekerja: baik `nohup ... &`
# maupun `setsid ... &` sama-sama membuat sesi SSH putus begitu server start,
# meski stdout dan stderr sudah dialihkan ke berkas. systemd-run melepasnya
# ke cgroup sendiri, dan barulah ia stabil.
#
# Jangan pula menyalurkan keluarannya lewat pipe untuk keperluan debug:
#
#   timeout 20 rkrun rkaiq_3A_server | head -40     # SALAH
#
# head keluar setelah 40 baris, pipe tertutup, rkaiq mati kena SIGPIPE, dan
# $? melaporkan status head yaitu 0 -- terlihat seolah rkaiq "keluar sendiri
# dengan sukses". Ini sempat menyesatkan diagnosis cukup lama.
#
# ---------------------------------------------------------------------------
# DAMPAK 3A TERHADAP KUALITAS (terukur, frame yang sama, ruangan yang sama)
#
#   tanpa 3A : R=67,2  G=88,2   B=43,0   -> gelap, cast hijau jelas
#   dengan 3A: R=123,8 G=122,8  B=92,5   -> eksposur benar, warna netral
#
# Menariknya berkas justru jadi LEBIH KECIL dengan 3A (9,2 KB/frame vs
# 39 KB/frame): eksposur yang benar menekan noise, dan noise mahal untuk
# dikodekan.

set -e

W=${1:-1280}
H=${2:-720}
N=${3:-300}
CODEC=${CODEC:-h264}
OUT=${OUT:-/home/pico/rekaman}
AIQ=${AIQ:-1}
EXPO=${EXPO:-1200}
GAIN=${GAIN:-512}
SD=${SD:-/dev/v4l-subdev2}

[ "$(id -u)" = 0 ] || { echo "jalankan sebagai root" >&2; exit 1; }
command -v rkrun >/dev/null 2>&1 || { echo "rkrun tidak ada -- pasang runtime uClibc dulu" >&2; exit 1; }

if [ ! -c /dev/video11 ]; then
	echo "ISP belum siap (/dev/video11 tidak ada)." >&2
	echo "Jalankan: sudo sh luckfox-venc-up.sh" >&2
	exit 1
fi
[ -c /dev/mpp_service ] || { echo "encoder belum siap (/dev/mpp_service)" >&2; exit 1; }

# Simpan ke penyimpanan PERSISTEN, jangan /tmp. Kalau board direset watchdog
# di tengah percobaan -- dan pada resolusi tinggi itu benar-benar terjadi --
# isi /tmp ikut hilang bersama rekamannya.
mkdir -p "$OUT"
FILE="$OUT/rec-${W}x${H}.$CODEC"

if [ "$AIQ" = "1" ]; then
	echo "== jalankan 3A (rkaiq_3A_server) =="
	systemctl stop rkaiq.service 2>/dev/null || true
	systemd-run --unit=rkaiq --collect --quiet /usr/local/bin/rkrun rkaiq_3A_server
	sleep 10
	if [ "$(systemctl is-active rkaiq.service)" = "active" ]; then
		echo "   aktif"
	else
		echo "   GAGAL start -- lanjut tanpa 3A" >&2
		AIQ=0
	fi
fi

if [ "$AIQ" != "1" ]; then
	echo "== tanpa 3A: eksposur diatur manual =="
	# Tanpa daemon 3A tidak ada auto-exposure; sensor default menghasilkan
	# frame nyaris hitam yang terkompresi jadi ~150 byte/frame.
	v4l2-ctl -d "$SD" --set-ctrl=exposure=$EXPO,analogue_gain=$GAIN 2>/dev/null || true
	v4l2-ctl -d "$SD" --get-ctrl=exposure,analogue_gain 2>/dev/null | sed 's/^/   /'
fi

echo "== rekam ${W}x${H} $CODEC, $N frame -> $FILE =="
rm -f "$FILE"
T0=$(date +%s%N)
set +e
rkrun simple_vi_bind_venc -I 0 -w "$W" -h "$H" -e "$CODEC" -c "$N" -o "$FILE" > /tmp/rec.log 2>&1
RC=$?
set -e
T1=$(date +%s%N)
DUR=$(( (T1 - T0) / 1000000 ))
sync

[ "$AIQ" = "1" ] && systemctl stop rkaiq.service 2>/dev/null || true

SZ=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
echo "   exit=$RC  durasi=${DUR}ms  ukuran=${SZ} byte"

if [ "$SZ" -eq 0 ]; then
	echo "   GAGAL. 10 baris terakhir log:" >&2
	grep -viE '^[[:space:]]*$' /tmp/rec.log | tail -10 | sed 's/^/     /' >&2
	echo >&2
	echo "   Kalau menggantung berulang, kemungkinan besar rockit ter-Oops." >&2
	echo "   Periksa: dmesg | grep mpi_fs_buf_loop_add" >&2
	echo "   Kalau ada, reboot -- state video tidak bisa dipulihkan tanpa itu." >&2
	exit 1
fi

# fps sebenarnya dihitung dari cap waktu stream-on/off milik ISP, bukan dari
# lama proses, karena proses juga menghabiskan waktu untuk init dan teardown.
grep -E 'ispStreamOn +:511|ispStreamOff +:521' /tmp/rec.log | sed 's/^/   /' || true
[ "$DUR" -gt 0 ] && echo "   bitrate (atas dasar durasi proses): $(( SZ * 8 / DUR )) kbps"

chown -R pico:pico "$OUT" 2>/dev/null || true
ls -l "$FILE" | sed 's/^/   /'

echo
echo "Putar di PC:"
echo "  ffmpeg -fflags +genpts -r 30 -i rec-${W}x${H}.$CODEC -c copy rec.mp4"
