# Luckfox Pico Mini B — Kamera CSI (SC3336) di Ubuntu

Menjalankan kamera MIPI CSI-2 pada image **Ubuntu** Luckfox — bukan Buildroot.

Banyak sumber (termasuk catatan saya sendiri sebelumnya) menyimpulkan kamera tidak bisa jalan
di Ubuntu karena RAM 56 MB terlalu sempit. **Kesimpulan itu salah.** Masalahnya bukan total RAM,
melainkan **fragmentasi memori** dan **urutan pemuatan modul**.

![Frame mentah 640x480 dari SC3336](images/sample-640x480-bayer.png)

*Frame nyata dari sensor: kusen pintu dan kursi. Garis vertikal halus adalah pola Bayer yang
belum di-demosaic — normal untuk data mentah langsung dari CIF tanpa pemrosesan ISP.*

---

## Ringkasan hasil

| Hal | Status |
|---|---|
| Sensor SC3336 terdeteksi | ✅ `Detected OV00cc41 sensor` di I2C bus 4, alamat 0x30 |
| ISP probe | ✅ berhasil setelah kompaksi memori |
| Tautan sensor → CIF | ✅ `Async subdev notifier completed` |
| Format ternegosiasi | ✅ `SBGGR10_1X10/2304x1296` |
| Tangkap frame 320×240 | ✅ 122.880 byte (CMA bawaan) |
| Tangkap frame 640×480 | ✅ 491.520 byte (CMA bawaan) |
| Tangkap frame 1280×720 | ✅ dengan `rk_dma_heap_cma=16M` |
| Tangkap frame 2304×1296 | ✅ 3.981.312 byte dengan `rk_dma_heap_cma=16M` |

Diuji pada Ubuntu 22.04.3 LTS armhf, kernel 5.10.160, board Luckfox Pico Mini B.

---

## Masalah 1 — ISP gagal probe: fragmentasi, bukan kekurangan RAM

Gejalanya:

```
rkisp_hw ffa00000.rkisp: No reserved memory region. default cma area!
[<b0228c3b>] (devm_kmalloc) from [<af863e0d>] (rkisp_plat_probe+0x39/0x514 [video_rkisp])
rkisp: probe of rkisp-vir0 failed with error -12
```

`-12` = ENOMEM. Yang gagal adalah **`devm_kmalloc`** — alokasi memori kernel biasa yang
membutuhkan **halaman fisik kontigu**. Alokasi orde tinggi bisa gagal meski `MemFree` besar,
kalau memori sudah terfragmentasi.

Buktinya ada di `/proc/buddyinfo` — jumlah blok bebas per orde (kiri orde-0 = 4 KB,
makin ke kanan makin besar):

```
sebelum kompaksi : 738  663  134   25   19    9    5    4    0
sesudah kompaksi :  11   64   65   36   22   11    7    6    8
                                                        ↑ orde-8
```

Sebelum kompaksi, **orde tertinggi berjumlah nol** padahal `MemFree` 17 MB: banyak halaman kecil,
tidak ada blok besar. Setelah `drop_caches` + `compact_memory`, orde-8 terisi dan probe berhasil.

> **Kenapa memori sudah terfragmentasi padahal uptime baru ~20 detik?**
> Modul kamera dimuat dari `rc.local`, yang berjalan **di akhir** rantai boot setelah systemd
> menyalakan hampir semua layanan. Angka uptime kecil menyesatkan — puluhan proses sudah lahir
> dan mati sebelum itu.

> **Jangan tertipu baris `No reserved memory region. default cma area!`.** Itu hanya informasi
> bahwa ISP akan memakai CMA default, bukan penyebab kegagalan. Menaikkan `rk_dma_heap_cma`
> untuk memperbaiki probe **tidak berhasil** dan justru memangkas `MemTotal` dari 57 MB ke 42 MB —
> memperburuk, karena `devm_kmalloc` butuh RAM normal, bukan CMA.

## Masalah 2 — Urutan pemuatan modul

Memuat `video_rkcif` sebelum driver sensor membuat async notifier gagal menautkannya:

```
rkcif-mipi-lvds: get_remote_sensor: remote pad is null
rkcif_update_sensor_info: stream[0] get remote sensor_sd failed!
```

Urutan yang benar (mengikuti `insmod_ko.sh` bawaan Luckfox):

```
rk_dvbm → sc3336 → video_rkcif → video_rkisp
        → phy-rockchip-csi2-dphy-hw → phy-rockchip-csi2-dphy
        → clr_unready_dev untuk rkcif dan rkisp
```

Penanda berhasil:

```
rockchip-csi2-dphy csi2-dphy0: dphy0 matches m00_b_sc3336 4-0030
rkcif-mipi-lvds: Async subdev notifier completed
rkisp rkisp-vir0: clear unready subdev num: 0
```

> `rockit`, `mpp_vcodec`, `rga3`, dan `rknpu` **tidak perlu** dimuat untuk capture V4L2 mentah.
> `rockit` justru merugikan: ia menelurkan sepuluh thread yang tersangkut permanen di state D
> (`vlog valloc vsys vrga_0 vrga_1 venc rkisp-vir0 vpss vrgn vmcu`), membuat load average board
> idle melonjak ke ~10 padahal CPU 99% idle. Thread itu juga tidak bisa dilepas — `rmmod`
> menggantung selamanya.

## Masalah 3 — CMA membatasi resolusi

Setelah pipeline jalan, alokasi buffer capture gagal di resolusi besar:

```
vb2_cma_sg_alloc_contiguous: cma_en:1 alloc pages fail
VIDIOC_REQBUFS returned -1 (Cannot allocate memory)
```

Buffer capture diambil dari **CMA**, yang bawaannya hanya 1 MB (`rk_dma_heap_cma=1M`).
Kebutuhan per frame RAW10:

| Resolusi | Size Image | 2 buffer | Muat di CMA 1 MB? |
|---|---:|---:|---|
| 320×240 | 122.880 | 245.760 | ✅ |
| 640×480 | 491.520 | 983.040 | ✅ (pas) |
| 1280×720 | 1.290.240 | 2.580.480 | ❌ |
| 2304×1296 | 3.981.312 | 7.962.624 | ❌ |

**Di sinilah menaikkan CMA benar-benar tepat** — berbeda dari kasus probe ISP tadi.

Caranya ada di repo Wiki, Bagian 12 (`scripts/uboot/patch_bootargs.py`) — `fw_setenv` tidak
tersedia dan Ctrl+C tidak menginterupsi U-Boot, jadi partisi env ditulis langsung dengan
CRC32 dihitung ulang:

```bash
sudo dd if=/dev/mmcblk1p1 of=/tmp/env.bin bs=1k count=32
sudo python3 patch_bootargs.py /tmp/env.bin /tmp/env16.bin \
     "rk_dma_heap_cma=1M" "rk_dma_heap_cma=16M"
sudo dd if=/tmp/env16.bin of=/dev/mmcblk1p1 bs=1k count=32 conv=fsync
sync && sudo reboot
```

### Hasil dengan CMA 16 MB

![Frame 2304x1296 dengan CMA 16M](images/sample-2304x1296-cma16m.png)

*Resolusi penuh SC3336. Pratinjau diperkecil 2×; garis Bayer jadi kurang tampak karena
penyampelan, dan struktur pemandangan terlihat jelas.*

```
Size Image : 3.981.312 byte
statistik  : min/max 0/255, rata-rata 62,6, 256 nilai unik
```

256 nilai unik berarti seluruh rentang dinamis 8-bit terpakai.

### Biaya memori yang terukur

| | CMA 1 MB | CMA 16 MB |
|---|---:|---:|
| `MemTotal` | 57.372 kB | 42.012 kB |
| `MemAvailable` (idle) | ~30.000 kB | ~21.000 kB |
| Resolusi maksimum | 640×480 | 2304×1296 |

**Kamera dan layanan lain bisa berdampingan.** Diuji dengan mosquitto + publisher telemetri
berjalan bersamaan pada CMA 16 MB: `MemAvailable` tetap ~21 MB dan semuanya stabil. Jadi
menaikkan CMA tidak berarti mengorbankan proyek lain di board yang sama — hanya menyempitkan
ruang gerak.

---

## Pemakaian

### 1. Muat tumpukan kamera

```bash
sudo sh scripts/luckfox-camera-up.sh
```

Skrip melakukan kompaksi memori lebih dulu, lalu memuat modul dengan urutan yang benar.

### 2. Tangkap frame

```bash
sudo sh scripts/capture.sh              # 640x480 ke /tmp/shot.raw + shot.pgm
sudo sh scripts/capture.sh 320 240
```

### 3. Lihat hasilnya

File `.pgm` bisa dibuka langsung oleh GIMP, IrfanView, atau `feh`. Untuk mengubah ke PNG:

```bash
python3 scripts/raw10_to_pgm.py /tmp/shot.raw /tmp/shot.pgm 640 480 1024
```

Argumen terakhir adalah **stride** (`Bytes per Line` dari `v4l2-ctl --get-fmt-video`),
yang tidak sama dengan lebar × 10/8 karena ada padding.

---

## Verifikasi bahwa datanya nyata

Jangan puas melihat file berukuran benar — frame konstan juga berukuran benar. Yang membuktikan
sensor sungguhan menangkap:

```bash
# tiga frame berturut-turut harus BERBEDA (noise sensor)
md5sum /tmp/f1.raw /tmp/f2.raw /tmp/f3.raw

# histogram harus punya banyak nilai unik, bukan satu-dua
od -A n -t u1 -v /tmp/f1.raw | tr -s ' ' '\n' | sort -u | wc -l
```

Hasil pada pengujian ini: ketiga MD5 berbeda, 220 nilai unik, min 0 / max 255 / rata-rata 96,8.

> Pemeriksaan 16 byte pertama saja **menyesatkan** — kebetulan bisa jatuh di area seragam dan
> terlihat seperti pola berulang konstan. Gunakan statistik menyeluruh.

## Isi repo

```
scripts/luckfox-camera-up.sh   kompaksi memori + muat modul urutan benar
scripts/capture.sh             tangkap frame, konversi ke PGM
scripts/raw10_to_pgm.py        konversi RAW10 MIPI -> PGM 8-bit
images/                        contoh hasil tangkapan
```

## Batasan yang diketahui

- **Capture dari CIF, bukan ISP.** Data mentah Bayer tanpa demosaic, black level, white balance,
  atau gamma. Untuk gambar siap pakai perlu memakai jalur `rkisp_mainpath` dengan parameter ISP,
  atau demosaic di sisi penerima.
- **Resolusi terbatas CMA bawaan.** 640×480 tanpa perubahan; resolusi penuh perlu CMA 16 MB,
  yang memangkas `MemTotal` dari 57 MB ke 42 MB.
- **Kompaksi perlu diulang tiap boot.** Skrip menanganinya, tapi kalau modul dimuat sangat telat
  saat sistem sibuk, kompaksi bisa tidak cukup. Solusi yang lebih tuntas: kompilasi driver
  sebagai built-in (`=y`) agar alokasi terjadi saat kernel init.
- **`rkisp-isp-subdev` melaporkan** `Entity type ... was not initialized!` — peringatan yang
  tampaknya tidak menghalangi capture dari CIF.

## Repo terkait

- **Platform / wiki:** https://github.com/apinblogsite/luckfox_pico_mini_B-Wiki
- **Telemetri MQTT:** https://github.com/apinblogsite/luckfox_pico_mini_B-Telemetry

## Lisensi

MIT.
