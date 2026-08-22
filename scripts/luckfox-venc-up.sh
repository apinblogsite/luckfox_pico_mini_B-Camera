#!/bin/sh
# Muat tumpukan LENGKAP untuk merekam video: kamera + encoder + rockit.
#
# Ini superset dari luckfox-camera-up.sh. Kalau Anda hanya butuh capture
# gambar diam lewat V4L2, pakai skrip itu saja -- ia lebih ringan dan tidak
# memuat rockit.
#
# ================== PELAJARAN MAHAL: KOMPAKSI SEBELUM ROCKIT ==================
#
# rockit.ko GAGAL dimuat dengan cara yang merusak kalau halaman kontigu
# orde-tinggi habis. Jejak aslinya:
#
#   insmod: page allocation failure: order:4, mode:GFP_KERNEL|__GFP_COMP
#     __kmalloc <- mpi_fs_buf_init <- vlog_probe <- mpi_init <- init_module [rockit]
#   Normal: 95*4kB 47*8kB 50*16kB 12*32kB 0*64kB 0*128kB ... = 1940kB
#
# order:4 = 16 halaman = 64 KB kontigu. Perhatikan 0*64kB dan seterusnya:
# tidak ada satu pun blok sebesar itu, padahal MemAvailable masih ~14 MB.
# Sama persis dengan kasus probe ISP -- soal FRAGMENTASI, bukan total RAM.
#
# Yang membuatnya jauh lebih buruk daripada sekadar "gagal muat": jalur
# penanganan error rockit sendiri punya bug. Setelah vlog_probe gagal,
# valloc_probe tetap memanggil vlog yang men-dereference buffer yang tidak
# pernah teralokasi:
#
#   Unable to handle kernel NULL pointer dereference at virtual address 00000000
#   PC is at mpi_fs_buf_loop_add+0x40/0x44 [rockit]
#
# Akibatnya rockit tinggal setengah jadi dan SELURUH subsistem video tersangkut.
# Gejalanya sangat menyesatkan: rekaman pertama setelah boot berhasil, lalu
# semua percobaan berikutnya menggantung sampai timeout -- termasuk resolusi
# yang tadinya jelas-jelas bekerja. Board pada akhirnya menggantung total dan
# hanya pulih karena watchdog perangkat keras.
#
# Karena itu skrip ini mengompaksi memori TEPAT SEBELUM insmod rockit, bukan
# hanya sekali di awal, dan MENOLAK memuat kalau blok orde-4 tetap nol.
# Menolak jauh lebih baik daripada memicu Oops yang mengharuskan reboot.
#
# Pakai: sudo sh luckfox-venc-up.sh

KO=/oem/usr/ko

ins() {
	m=$(basename "$1" .ko | tr - _)
	if [ -f "$KO/$1" ] && ! lsmod | grep -q "^$m "; then
		insmod "$KO/$1" 2>&1 && echo "  + $1"
	fi
	return 0
}

compact() {
	sync
	echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
	sleep 2
}

# Jumlah blok bebas pada orde ke-$1 (0-indeks) dari /proc/buddyinfo.
order_free() {
	awk -v o="$1" '/Normal/ { print $(5 + o); exit }' /proc/buddyinfo
}

[ "$(id -u)" = 0 ] || { echo "jalankan sebagai root" >&2; exit 1; }

echo "== kompaksi awal =="
compact
echo "  buddyinfo: $(awk '{$1=$2=$3=$4=""; print}' /proc/buddyinfo)"

# rc.local bawaan tidak melakukan ini; RkLunch.sh vendor melakukannya.
echo 1 > /proc/sys/vm/overcommit_memory

echo "== kamera (urutan penting: sensor sebelum rkcif) =="
ins rk_dvbm.ko
ins sc3336.ko
ins video_rkcif.ko
ins video_rkisp.ko
ins phy-rockchip-csi2-dphy-hw.ko
ins phy-rockchip-csi2-dphy.ko
sleep 1
echo 1 > /sys/module/video_rkcif/parameters/clr_unready_dev 2>/dev/null
echo 1 > /sys/module/video_rkisp/parameters/clr_unready_dev 2>/dev/null
sleep 2

echo "== encoder =="
ins mpp_vcodec.ko          # butuh rk_dvbm lebih dulu (simbol rk_dvbm_*)
ins rga3.ko                # rockit butuh simbol rga_mpi_commit dari sini

echo "== kompaksi LAGI, tepat sebelum rockit =="
compact
echo "  buddyinfo: $(awk '{$1=$2=$3=$4=""; print}' /proc/buddyinfo)"

O4=$(order_free 4)
O4=${O4:-0}
if [ "$O4" -lt 1 ]; then
	echo "  BATAL: blok orde-4 (64 KB) = 0 setelah kompaksi." >&2
	echo "  Memuat rockit sekarang akan memicu Oops dan menyangkutkan video." >&2
	echo "  Hentikan layanan yang tidak perlu lalu ulangi, atau reboot." >&2
	exit 1
fi
echo "  blok orde-4 tersedia: $O4 -- aman"
ins rockit.ko
sleep 1

echo "== hasil =="
# Periksa KEADAAN SEKARANG, bukan isi dmesg. dmesg adalah buffer melingkar yang
# menyimpan kegagalan dari percobaan sebelumnya dalam boot yang sama, sehingga
# grep ke sana melaporkan gagal padahal pemuatan kali ini berhasil -- dan
# sebaliknya tidak melaporkan apa-apa kalau buffer sudah berputar.
# /dev/video11 adalah rkisp_mainpath: ada berarti ISP benar-benar probe.
if [ -c /dev/video11 ]; then
	echo "  ISP probe OK (/dev/video11 ada)"
else
	echo "  ISP GAGAL probe -- /dev/video11 tidak ada" >&2
	echo "  Biasanya karena memori sudah sesak. Reboot lalu jalankan skrip ini" >&2
	echo "  sedini mungkin, sebelum layanan lain sempat memfragmentasi memori." >&2
fi
[ -c /dev/mpp_service ] && echo "  /dev/mpp_service ada" || echo "  /dev/mpp_service TIDAK ada"

# Oops rockit hanya relevan kalau terjadi pada pemuatan ini. Hitung sebelum dan
# sesudah tidak praktis di sini, jadi cukup laporkan sebagai peringatan lunak.
if dmesg | grep -q "mpi_fs_buf_loop_add"; then
	echo "  PERINGATAN: ada Oops rockit di dmesg boot ini." >&2
	echo "  Kalau perekaman menggantung, reboot -- state video tidak bisa dipulihkan." >&2
fi

# Load average tinggi setelah pemuatan menandakan thread rockit tersangkut di
# state D, yang selalu berarti ISP tidak siap saat rockit start.
echo "  load: $(cut -d" " -f1-3 /proc/loadavg)"
echo "  modul: $(lsmod | awk 'NR>1{print $1}' | tr '\n' ' ')"
free -m | head -2 | sed 's/^/  /'
