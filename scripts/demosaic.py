#!/usr/bin/env python3
"""Demosaic RAW10 Bayer dari Luckfox CIF menjadi gambar warna.

Dipakai kalau jalur ISP tidak tersedia. Data dari rkcif adalah Bayer mentah
tanpa demosaic, white balance, atau gamma -- semua itu dikerjakan di sini.

Langkahnya:
  1. Unpack MIPI RAW10 (5 byte = 4 piksel) ke 10-bit
  2. Kurangi black level
  3. Demosaic bilinear sesuai pola Bayer
  4. Grey-world white balance
  5. Gamma sRGB

Keluaran PPM (P6). Konversi ke PNG di sisi pemanggil, agar tidak butuh PIL.

Pakai:
  python3 demosaic.py in.raw out.ppm <width> <height> <stride> [pattern]

pattern: BGGR (default, untuk pixelformat BG10), atau RGGB / GRBG / GBRG.
Kalau warnanya terbalik (langit jadi merah), coba pattern lain.
"""
import sys

import numpy as np


def unpack_raw10(data, w, h, stride):
    """MIPI RAW10: tiap 5 byte memuat 4 piksel.
    byte 0..3 = 8 bit atas piksel 0..3, byte 4 = 2 bit bawah keempatnya."""
    out = np.zeros((h, w), dtype=np.uint16)
    groups = w // 4
    for y in range(h):
        row = np.frombuffer(data, dtype=np.uint8, count=groups * 5, offset=y * stride)
        g = row.reshape(groups, 5).astype(np.uint16)
        lo = g[:, 4]
        px = np.empty((groups, 4), dtype=np.uint16)
        for i in range(4):
            px[:, i] = (g[:, i] << 2) | ((lo >> (2 * i)) & 0x3)
        out[y, : groups * 4] = px.reshape(-1)
    return out


def demosaic(bayer, pattern):
    """Bilinear sederhana. Cukup untuk pratinjau; bukan kualitas ISP."""
    h, w = bayer.shape
    r = np.zeros((h, w), dtype=np.float32)
    g = np.zeros((h, w), dtype=np.float32)
    b = np.zeros((h, w), dtype=np.float32)

    # posisi (baris, kolom) genap/ganjil untuk tiap kanal
    pos = {
        "BGGR": {"B": (0, 0), "G1": (0, 1), "G2": (1, 0), "R": (1, 1)},
        "RGGB": {"R": (0, 0), "G1": (0, 1), "G2": (1, 0), "B": (1, 1)},
        "GRBG": {"G1": (0, 0), "R": (0, 1), "B": (1, 0), "G2": (1, 1)},
        "GBRG": {"G1": (0, 0), "B": (0, 1), "R": (1, 0), "G2": (1, 1)},
    }[pattern]

    f = bayer.astype(np.float32)
    for name, (oy, ox) in pos.items():
        ch = {"R": r, "B": b}.get(name[0], g)
        ch[oy::2, ox::2] = f[oy::2, ox::2]

    def fill(ch, mask):
        """isi piksel kosong dengan rata-rata tetangga yang terisi"""
        acc = np.zeros_like(ch)
        cnt = np.zeros_like(ch)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
            sh = np.roll(np.roll(ch, dy, axis=0), dx, axis=1)
            sm = np.roll(np.roll(mask, dy, axis=0), dx, axis=1)
            acc += sh * sm
            cnt += sm
        cnt[cnt == 0] = 1
        avg = acc / cnt
        return np.where(mask, ch, avg)

    mr = np.zeros((h, w), np.float32); mr[pos["R"][0]::2, pos["R"][1]::2] = 1
    mb = np.zeros((h, w), np.float32); mb[pos["B"][0]::2, pos["B"][1]::2] = 1
    mg = np.zeros((h, w), np.float32)
    mg[pos["G1"][0]::2, pos["G1"][1]::2] = 1
    mg[pos["G2"][0]::2, pos["G2"][1]::2] = 1

    r = fill(r, mr)
    b = fill(b, mb)
    g = fill(g, mg)
    return r, g, b


def main():
    if len(sys.argv) not in (6, 7):
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    w, h, stride = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    pattern = sys.argv[6].upper() if len(sys.argv) == 7 else "BGGR"

    data = open(src, "rb").read()
    if len(data) < stride * h:
        print(f"data kurang: {len(data)} < {stride*h}")
        return 1

    bayer = unpack_raw10(data, w, h, stride)
    print(f"unpack: {bayer.shape}, min {bayer.min()} max {bayer.max()}")

    # black level: SC3336 biasanya 64 pada skala 10-bit
    black = 64.0
    bayer = np.clip(bayer.astype(np.float32) - black, 0, None)

    r, g, b = demosaic(bayer, pattern)

    # grey-world white balance
    mr, mg, mb = r.mean(), g.mean(), b.mean()
    print(f"rata-rata kanal  R {mr:.1f}  G {mg:.1f}  B {mb:.1f}")
    if mr > 0 and mb > 0:
        r *= mg / mr
        b *= mg / mb

    # normalisasi ke 0..1 memakai persentil agar tidak dirusak hot pixel
    stack = np.stack([r, g, b])
    hi = np.percentile(stack, 99.5)
    if hi <= 0:
        hi = 1.0
    stack = np.clip(stack / hi, 0, 1)

    # gamma sRGB
    a = 0.055
    srgb = np.where(stack <= 0.0031308, stack * 12.92, (1 + a) * np.power(stack, 1 / 2.4) - a)
    img = (srgb * 255).astype(np.uint8)

    rgb = np.stack([img[0], img[1], img[2]], axis=-1)
    with open(dst, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(rgb.tobytes())
    print(f"ditulis {dst}: {w}x{h} RGB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
