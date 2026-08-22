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
| **Gambar siap pakai via ISP** | ✅ NV12 dari `rkisp_mainpath`, tajam & tanpa noise kroma |
| ISP resolusi penuh 2304×1296 | ✅ 4.478.976 byte dengan `rk_dma_heap_cma=16M` |
| **Rekam video H.264 720p** | ✅ 29,8 fps, didekode ulang 301/301 frame tanpa galat |
| **Rekam video H.264 1080p** | ✅ 29,2 fps |
| Rekam video 2304×1296 | ❌ menggantungkan board — hanya pulih lewat watchdog |
| **3A otomatis (rkaiq)** | ✅ eksposur dan white balance benar |
| Rekonstruksi warna dari raw di penerima | ❌ belum terpecahkan (lihat Masalah 4) |

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

## Masalah 4 — Warna: kendali eksposur berhasil, rekonstruksi warna belum

Frame mentah dari CIF adalah Bayer tanpa demosaic. Upaya merekonstruksi warna di sisi
penerima **belum berhasil**, dan ini catatan jujur tentang sejauh mana penelusurannya sampai.

### Eksposur dan gain harus diatur manual

Tanpa `rkaiq`, tidak ada auto-exposure. Sensor memakai default yang sangat gelap:

```
exposure      : min=1   max=1352   value=128    <- hampir minimum
analogue_gain : min=128 max=99614  value=128    <- minimum
```

Subdev sensor adalah yang punya kontrol ini — cari dengan:

```bash
for d in /dev/v4l-subdev*; do
  v4l2-ctl -d $d --list-ctrls 2>/dev/null | grep -qi exposure && echo "$d"
done
```

Hasil sapuan pada scene dalam ruangan (rata-rata byte dari 400 KB pertama):

| exposure | rata-rata | | gain (exp=1200) | rata-rata |
|---:|---:|---|---:|---:|
| 128 | 66,3 | | 128 | 102,5 |
| 400 | 85,6 | | 256 | 113,1 |
| 800 | 96,5 | | 512 | 130,9 |
| 1200 | **101,1** | | 1024 | 158,0 |
| 1340 | 96,8 | | 2048 | 190,3 |

Eksposur mentok di ~101 pada nilai 1200 lalu turun (melampaui batas frame timing);
selebihnya harus dari gain. `exposure=1200, analogue_gain=512` memberi eksposur seimbang.

### Yang sudah dieliminasi

- **Pola Bayer salah?** Keempat kemungkinan (BGGR/RGGB/GRBG/GBRG) diuji — semuanya buruk
  dengan cast berbeda. Kalau sekadar salah pola, satu di antaranya akan wajar.
- **Demosaic salah?** Diuji dengan data sintetis: delapan bilah warna dimosaic lalu
  didemosaic, **selisih nol**. Implementasinya benar.
- **Aliasing pratinjau?** Awalnya memperkecil gambar dengan point sampling — itu memang
  memperburuk (fase Bayer berulang tiap 2 piksel), tapi setelah diganti rata-rata blok,
  noise kroma tetap ada.
- **Eksposur kurang?** Setelah dinaikkan ke rata-rata 131, noise kroma justru makin jelas.
- **Data rusak?** Pola uji sensor (`test_pattern=1`) menampilkan bilah hitam dan putih
  sebagai blok seragam yang benar. Bilah berwarna tampil bergaris — itu **wajar** di domain
  Bayer mentah, karena R/G/B dalam satu bilah punya nilai berbeda.

### Dugaan yang tersisa

Gejalanya khas: **luminansi bagus, kroma hancur**. Grayscale tajam dan detail benar, tapi
pemisahan per kanal menghasilkan noise. Kalau fase Bayer bergeser antar-baris — misalnya R
dan B tertukar di baris berselang — luminansi tetap utuh sementara warna rusak total.

Petunjuk pendukung: **byte 2880–2919 tiap baris berisi data terstruktur berulang, bukan
padding nol**. Jadi asumsi "area aktif = 2880 byte pertama" mungkin tidak tepat, dan offset
awal tiap baris bisa bergeser terhadap batas grup 5-byte MIPI RAW10.

Menelusuri lebih jauh berarti membedah tata letak buffer `vb2_cma_sg` di driver `rkcif`.

### Kesimpulan praktis

Untuk gambar siap pakai, **gunakan ISP, jangan rekonstruksi di penerima** — lihat bagian
berikutnya. Terbukti jauh lebih baik dan jauh lebih sedikit usaha.

---

## Jalur ISP — gambar siap pakai ✅

Ini jawabannya, dan ternyata **jauh lebih mudah dari dugaan**.

### Ada link langsung CIF → ISP

Topologi `media1` menunjukkan jalur langsung yang **sudah aktif**, tanpa perlu mode readback
lewat memori:

```
rkisp-isp-subdev pad0 (Sink)  : [fmt:SBGGR10_1X10/2304x1296]
                                <- "rkcif-mipi-lvds":0 [ENABLED]
                 pad1 (Sink)  : <- "rkisp-input-params":0 [ENABLED]
                 pad2 (Source): [fmt:YUYV8_2X8/2304x1296]
                                -> "rkisp_mainpath":0 [ENABLED]
```

Keluaran ISP sudah dalam domain **YUV** — demosaic dikerjakan di silikon. Format yang didukung
`rkisp_mainpath` (`/dev/video11`): UYVY, NV16, NV61, NV21, NV12, NM21, NM12.

### Menangkap

```bash
sudo sh scripts/capture_isp.sh              # 1280x720 NV12
sudo sh scripts/capture_isp.sh 2304 1296
```

Tanpa konfigurasi link manual, tanpa `media-ctl`, tanpa `rkaiq`. Cukup set format dan stream.

![Hasil ISP dengan koreksi white balance](images/sample-isp-1280x720-awb.png)

*Keluaran ISP 1280×720 NV12, dikonversi ke RGB dengan koreksi grey-world. Tajam, tanpa noise
kroma, detail halus terbaca — bandingkan dengan hasil demosaic manual di atas.*

### Resolusi penuh juga berhasil

![ISP 2304x1296 NV12 dengan koreksi white balance](images/sample-isp-2304x1296-awb.png)

*Resolusi penuh SC3336 lewat ISP, pratinjau diperkecil 2×. Tekstur dinding, kabel di lantai,
tepi rak, dan bayangan semuanya terbaca bersih — bandingkan dengan hasil demosaic manual pada
data mentah di bagian sebelumnya.*

```
2304×1296 NV12  ->  4.478.976 byte   (2304 × 1296 × 1,5)
luma            :   min 17, max 255, rata-rata 95,0
kroma sebelum WB:   U -25,0   V -10,1
```

Butuh `rk_dma_heap_cma=16M` seperti jalur raw. Dua buffer NV12 resolusi penuh ≈ 8,5 MB.

Nilai kroma konsisten antar-pengambilan (`U` sekitar −23…−25, `V` sekitar −9…−10), menandakan
cast hijau itu berasal dari gain WB default ISP yang tetap — bukan variasi scene.

### Perbandingan langsung

| | Raw CIF + demosaic manual | ISP `mainpath` |
|---|---|---|
| Demosaic | di penerima (CPU) | di silikon |
| Denoise, lens shading, black level | tidak ada | ada |
| Noise kroma | berat, belum teratasi | **tidak ada** |
| Ketajaman | baik (luminansi) | baik |
| Format keluaran | Bayer RAW10 | YUV (NV12 dll) |
| Ukuran 1280×720 | 1.290.240 byte | 1.382.400 byte |
| Ukuran 2304×1296 | 3.981.312 byte | 4.478.976 byte |
| Usaha | tinggi, dan gagal | rendah, dan berhasil |

### Yang masih perlu ditangani manual

Tanpa daemon `rkaiq`, tidak ada 3A otomatis:

- **Eksposur** — atur lewat kontrol subdev sensor (`exposure`, `analogue_gain`)
- **White balance** — ISP memakai gain default, hasilnya bercast hijau. Statistik kroma pada
  pengujian: `U rata2 -24.8`, `V rata2 -9.9` (keduanya negatif = bias hijau)

Koreksi WB paling bersih dilakukan **di domain kroma**, bukan dengan mengalikan kanal RGB —
geser pusat U dan V ke nol, sehingga luma tidak tersentuh:

```python
u = u - u.mean()
v = v - v.mean()
```

Itulah yang dilakukan `nv12_to_ppm.py ... awb`.

> **Diperbarui.** Kalimat sebelumnya di sini menyatakan bahwa 3A sungguhan lewat `rkaiq`
> "mengembalikan sepuluh thread state D serta load average ~10". Itu **keliru**, dan sudah
> dibuktikan sebaliknya saat mengerjakan perekaman video: `rkaiq_3A_server` berjalan normal
> dan menghasilkan eksposur serta white balance yang benar. Load average ~10 berasal dari
> **`rockit` yang dimuat ketika ISP belum siap**, bukan dari rkaiq. Lihat bagian
> [Rekam video](#rekam-video-h264--h265--mjpeg).
>
> Untuk pengambilan gambar diam sesekali, mengatur eksposur manual dan mengoreksi WB saat
> konversi tetap jauh lebih murah daripada menjalankan seluruh tumpukan rockit.

## Rekam video (H.264 / H.265 / MJPEG)

RV1106 punya encoder video perangkat keras. Ia **bekerja**, dan hasilnya terverifikasi
sampai bisa didekode ulang di PC — bukan sekadar "berkasnya terbentuk".

| | Hasil |
|---|---|
| Resolusi terbukti | **1280×720** dan **1920×1080** |
| Codec | H.264 High profile, level 4.0 |
| Laju frame | **29,8 fps** (301 frame dalam 10,08 detik) |
| Bitrate | 1,7 Mbps dengan 3A, 8,2 Mbps tanpa 3A |
| Verifikasi | `ffmpeg` mendekode 301/301 frame, **nol galat** |

![Frame dari rekaman 720p dengan 3A aktif](images/video-1280x720-3a.png)

### Penghalang pertama: binernya tidak bisa dijalankan sama sekali

Seluruh perkakas video Rockchip ada di `/oem/usr/bin` — `simple_vi_bind_venc`,
`rkaiq_3A_server`, `rkipc`, dan puluhan lainnya. Tapi tak satu pun mau jalan:

```
sh: /oem/usr/bin/mpi_enc_test: not found
```

Pesan itu menyesatkan. Berkasnya jelas ada dan executable. "not found" datang dari `execve`
yang tidak menemukan **ELF interpreter**, bukan dari berkas programnya:

```
mpi_enc_test          -> /lib/ld-uClibc.so.0      (tidak ada di Ubuntu)
v4l2-ctl              -> /lib/ld-linux-armhf.so.3 (ada)
librockchip_mpp.so.1  -> NEEDED: libstdc++.so.6, libgcc_s.so.1, libc.so.0
```

Biner-biner itu dibangun untuk Buildroot/uClibc, sedangkan rootfs kita Ubuntu/glibc.
Penyelesaiannya: ambil runtime uClibc dari SDK Luckfox dan pasang **terpisah**, lalu
jalankan lewat pembungkus `rkrun`. Caranya ada di
[repo Wiki, Bagian 17](https://github.com/apinblogsite/luckfox_pico_mini_B-Wiki).

> **Jangan pernah `export LD_LIBRARY_PATH` yang memuat direktori uClibc itu.** Di dalamnya
> ada `libstdc++.so.6` dan `libgcc_s.so.1` dengan nama berkas yang sama persis seperti milik
> glibc. Begitu di-export, `v4l2-ctl`, `python3`, bahkan `ls` akan memungut versi yang salah
> dan langsung segfault. `rkrun` menyetel env hanya untuk satu proses.

### Penghalang kedua: rockit ter-Oops dan menyangkutkan seluruh video

Ini yang paling memakan waktu, karena gejalanya berbohong: **rekaman pertama setelah boot
berhasil, semua percobaan berikutnya menggantung** — termasuk resolusi yang barusan jelas
bekerja.

Penyebabnya terlihat di `dmesg`:

```
insmod: page allocation failure: order:4, mode:GFP_KERNEL|__GFP_COMP
  __kmalloc <- mpi_fs_buf_init <- vlog_probe <- mpi_init <- init_module [rockit]
Normal: 95*4kB 47*8kB 50*16kB 12*32kB 0*64kB 0*128kB ... = 1940kB

Unable to handle kernel NULL pointer dereference at virtual address 00000000
PC is at mpi_fs_buf_loop_add+0x40/0x44 [rockit]
```

`order:4` = 16 halaman = **64 KB kontigu**. Perhatikan `0*64kB` dan seterusnya: tidak ada
satu pun blok sebesar itu, padahal `MemAvailable` masih ~14 MB. **Fragmentasi, bukan
kekurangan RAM** — persis Masalah 1, tapi kali ini pada `rockit`.

Yang membuatnya jauh lebih buruk daripada sekadar gagal muat: jalur penanganan error rockit
sendiri punya bug. Setelah `vlog_probe` gagal, `valloc_probe` tetap memanggil `vlog` yang
men-dereference buffer yang tidak pernah teralokasi → **Oops kernel**. rockit lalu tinggal
setengah jadi dan seluruh subsistem video mati sampai reboot.

Kesalahan saya sendiri saat pertama menulis loader: kompaksi dilakukan sekali di awal, lalu
tujuh modul lain dimuat, dan `rockit` ditaruh **paling akhir** — saat blok orde-4 sudah habis
lagi. Perbaikannya: **kompaksi tepat sebelum `insmod rockit`**, dan tolak memuat kalau blok
orde-4 tetap nol. Menolak jauh lebih baik daripada memicu Oops.

```
== kompaksi LAGI, tepat sebelum rockit ==
  buddyinfo: 6 50 72 33 14 8 2 1 0
  blok orde-4 tersedia: 14 -- aman
  + rockit.ko
  rockit OK (tanpa Oops)
```

### Batas resolusi

| Resolusi | Hasil |
|---|---|
| 1280×720 | ✅ 29,8 fps, stabil |
| 1920×1080 | ✅ 29,2 fps, stabil |
| 2304×1296 | ❌ **menggantungkan board** — dua kali, hanya pulih karena watchdog perangkat keras |

Resolusi penuh sensor tidak bisa direkam di board ini. Capture **gambar diam** 2304×1296
lewat ISP tetap bisa (lihat bagian sebelumnya) — yang tidak muat adalah menjalankan ISP,
encoder, dan rockit sekaligus pada resolusi itu dengan RAM 42 MB dan CMA 16 MB.

> Kalau board Anda mati mendadak saat percobaan, rekaman di `/tmp` ikut hilang — `/tmp`
> adalah tmpfs. Simpan ke `/home/pico` seperti yang dilakukan skrip.

### 3A (rkaiq) mengubah hasilnya secara drastis

Tanpa `rkaiq_3A_server` tidak ada auto-exposure maupun AWB. Efeknya bukan sekadar "kurang
bagus" — pada percobaan pertama, seluruh rekaman praktis **hitam**: 147 byte per frame,
~35 kbps. Struktur H.264-nya sah sempurna, isinya saja yang kosong.

| | Tanpa 3A | Dengan 3A |
|---|---:|---:|
| Rata-rata R | 67,2 | **123,8** |
| Rata-rata G | 88,2 | **122,8** |
| Rata-rata B | 43,0 | **92,5** |
| Byte per frame | 39.185 | **9.229** |

Tanpa 3A, G jauh di atas R dan B — cast hijau, terukur. Dengan 3A, R dan G seimbang.

Perhatikan bahwa berkasnya justru **lebih kecil** dengan 3A. Itu bukan penurunan kualitas:
eksposur yang benar menekan noise sensor, dan noise mahal sekali untuk dikodekan.

| Tanpa 3A | Dengan 3A |
|---|---|
| ![tanpa 3A](images/video-1280x720-tanpa3a.png) | ![dengan 3A](images/video-1280x720-3a.png) |

**`rkaiq_3A_server` harus dijalankan lewat `systemd-run`.** Sebagai proses latar biasa dari
sesi SSH ia tidak stabil: baik `nohup ... &` maupun `setsid ... &` membuat sesi SSH putus
begitu server start, walaupun stdout dan stderr sudah dialihkan ke berkas.

Dan satu jebakan diagnosis yang sempat menyesatkan cukup lama — **jangan menyalurkan
keluarannya lewat pipe**:

```sh
timeout 20 rkrun rkaiq_3A_server | head -40     # SALAH
```

`head` keluar setelah 40 baris, pipe tertutup, rkaiq mati kena `SIGPIPE`, dan `$?` melaporkan
status `head` yaitu 0. Terlihat persis seperti "rkaiq keluar sendiri dengan sukses", padahal
harness ujinya sendiri yang membunuhnya.

### Setelah merekam, load average tinggal ~12 sampai reboot

Ini bukan kerusakan, tapi harus Anda ketahui sebelum menaruh board ini di tempat yang sulit
dijangkau. Begitu `rockit` dimuat, ia menelurkan sepuluh thread kernel yang **tidak pernah
keluar dari state D**, bahkan setelah perekaman selesai:

```
$ ps -eL -o pid,stat,comm | awk '$3 ~ /^D/'
1205 D vlog        1210 D venc
1206 D valloc      1211 D rkisp-vir0
1207 D vsys        1212 D vpss
1208 D vrga_0      1213 D vrgn
1209 D vrga_1      1214 D vmcu

$ cat /proc/loadavg
12.75 12.33 11.38 1/98
```

CPU-nya sendiri **menganggur**. Dua sampel `/proc/stat` berjarak 2 detik menunjukkan kolom
idle tidak bergerak sementara iowait naik 155 jiffy — thread-thread itu menunggu, bukan
bekerja. Suhu dan responsivitas board tetap normal.

Konsekuensi praktisnya:

- **Angka load average jadi tidak berguna** sebagai indikator kesehatan selama `rockit`
  termuat. Kalau Anda memantau lewat telemetri MQTT, `load1` akan terbaca ~12 terus.
- **`rmmod rockit` menggantung** dan tidak bisa dibatalkan — thread state D tidak dapat
  diinterupsi. Satu-satunya cara membersihkan adalah **reboot**.
- Karena itu jangan memuat `rockit` di boot kalau board Anda tidak selalu merekam. Muat saat
  dibutuhkan, dan reboot setelah selesai.

Ini masalah yang sama dengan Masalah 2 di atas, hanya penyebabnya berbeda: di sana `rockit`
tersangkut karena ISP gagal probe; di sini ia tersangkut karena memang begitu sifatnya setelah
dipakai.

### Pemakaian

```bash
# 1. muat tumpukan lengkap (kamera + encoder + rockit)
sudo sh scripts/luckfox-venc-up.sh

# 2. rekam
sudo sh scripts/luckfox-record.sh                    # 1280x720, 300 frame
sudo sh scripts/luckfox-record.sh 1920 1080 90
CODEC=h265 sudo sh scripts/luckfox-record.sh 1280 720 150
AIQ=0 sudo sh scripts/luckfox-record.sh              # tanpa 3A, eksposur manual
```

Hasilnya berupa aliran H.264 mentah (Annex B). Untuk memutarnya di PC, bungkus jadi MP4:

```bash
ffmpeg -fflags +genpts -r 30 -i rec-1280x720.h264 -c copy rec.mp4
```

Jalankan `luckfox-venc-up.sh` **sedini mungkin setelah boot**. Semakin lama board menyala,
semakin terfragmentasi memorinya, dan semakin besar peluang rockit gagal dimuat.

---

## Pemakaian (gambar diam)

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
scripts/luckfox-camera-up.sh   kompaksi memori + muat modul urutan benar (gambar diam)
scripts/luckfox-venc-up.sh     superset: + encoder + rockit, untuk video
scripts/luckfox-record.sh      rekam H.264/H.265/MJPEG, dengan atau tanpa 3A
scripts/capture.sh             tangkap frame, konversi ke PGM
scripts/capture_isp.sh         tangkap NV12 siap pakai lewat ISP
scripts/raw10_to_pgm.py        konversi RAW10 MIPI -> PGM 8-bit
scripts/nv12_to_ppm.py         konversi NV12 -> PPM, dengan koreksi WB opsional
images/                        contoh hasil tangkapan dan frame video
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
- **Video hanya sampai 1080p.** 2304×1296 menggantungkan board; lihat bagian
  [Rekam video](#rekam-video-h264--h265--mjpeg).
- **Perkakas video butuh runtime uClibc terpisah.** Biner di `/oem/usr/bin` dibangun untuk
  Buildroot dan tidak bisa jalan langsung di rootfs Ubuntu.
- **`rockit` rapuh terhadap fragmentasi.** Kalau blok orde-4 habis saat dimuat, ia ter-Oops
  dan menyangkutkan seluruh subsistem video sampai reboot. `luckfox-venc-up.sh` memeriksa
  ini lebih dulu dan menolak memuat daripada memicu Oops.
- **Load average tidak bisa dipercaya selama `rockit` termuat** — tinggal ~12 sampai reboot
  karena sepuluh thread state D yang tidak pernah keluar, meski CPU menganggur. `rmmod`
  menggantung; hanya reboot yang membersihkannya.

## Repo terkait

- **Platform / wiki:** https://github.com/apinblogsite/luckfox_pico_mini_B-Wiki
- **Telemetri MQTT:** https://github.com/apinblogsite/luckfox_pico_mini_B-Telemetry

## Lisensi

MIT.
