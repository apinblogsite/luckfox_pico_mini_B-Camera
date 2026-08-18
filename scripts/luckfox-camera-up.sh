#!/bin/sh
# Muat tumpukan kamera Luckfox dengan urutan yang benar, setelah kompaksi memori.
#
# Dua hal yang membuat ini bekerja padahal pemuatan bawaan gagal:
#
# 1. KOMPAKSI DULU. devm_kmalloc di rkisp_plat_probe butuh halaman fisik
#    kontigu orde tinggi. Saat rc.local berjalan, memori sudah terfragmentasi
#    oleh systemd -- buddyinfo orde-8 = 0 meski MemFree 17 MB, dan probe
#    gagal dengan -12 (ENOMEM). Setelah drop_caches + compact_memory,
#    orde-8 terisi dan probe berhasil.
#
# 2. URUTAN. Sensor harus terdaftar SEBELUM video_rkcif probe, kalau tidak
#    async notifier gagal menautkannya:
#      rkcif-mipi-lvds: get_remote_sensor: remote pad is null
#
# rockit, mpp_vcodec, rga3, dan rknpu sengaja TIDAK dimuat -- tidak
# diperlukan untuk capture V4L2 mentah, dan rockit-lah yang menelurkan
# sepuluh thread state D yang membuat load average melonjak ke 10.

KO=/oem/usr/ko

ins() {
	m=$(basename "$1" .ko | tr - _)
	if [ -f "$KO/$1" ] && ! lsmod | grep -q "^$m "; then
		insmod "$KO/$1" 2>/dev/null && echo "  + $1"
	fi
	return 0
}

echo "== kompaksi memori =="
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
sleep 2
echo "  buddyinfo: $(awk '{$1=$2=$3=$4=""; print}' /proc/buddyinfo)"

echo "== muat modul (urutan penting) =="
ins rk_dvbm.ko
ins sc3336.ko
ins video_rkcif.ko
ins video_rkisp.ko
ins phy-rockchip-csi2-dphy-hw.ko
ins phy-rockchip-csi2-dphy.ko
sleep 1

echo "== bersihkan subdev yang belum siap =="
echo 1 > /sys/module/video_rkcif/parameters/clr_unready_dev 2>/dev/null
echo 1 > /sys/module/video_rkisp/parameters/clr_unready_dev 2>/dev/null
sleep 2

echo "== hasil =="
if dmesg | grep -q 'probe of rkisp-vir0 failed'; then
	echo "  ISP GAGAL probe"
else
	echo "  ISP probe OK"
fi
dmesg | grep -icE 'remote pad is null' | while read n; do echo "  'remote pad is null': $n (harus 0)"; done
