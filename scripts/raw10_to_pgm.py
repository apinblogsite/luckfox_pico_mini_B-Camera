#!/usr/bin/env python3
"""Konversi RAW10 MIPI (dari rkcif) ke PGM 8-bit grayscale.

Kemasan MIPI RAW10: setiap 5 byte memuat 4 piksel.
  byte 0..3 = 8 bit atas piksel 0..3
  byte 4    = 2 bit bawah keempatnya
Untuk pratinjau, 8 bit atas sudah cukup -- byte ke-5 diabaikan.

Hasilnya masih pola Bayer (belum di-demosaic), jadi akan terlihat
bertekstur halus seperti kain. Itu normal untuk data mentah sensor.

Pakai: python3 raw10_to_pgm.py in.raw out.pgm <width> <height> <stride>
"""
import sys


def main():
    if len(sys.argv) != 6:
        print(__doc__)
        return 1
    src, dst, w, h, stride = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

    data = open(src, "rb").read()
    need = stride * h
    if len(data) < need:
        print(f"data kurang: {len(data)} < {need}")
        return 1

    out = bytearray()
    for y in range(h):
        row = data[y * stride : y * stride + stride]
        px = bytearray()
        # 4 piksel per 5 byte
        for i in range(0, (w // 4) * 5, 5):
            if i + 4 >= len(row):
                break
            px += bytes(row[i : i + 4])
        px = px[:w]
        px += bytes(w - len(px))
        out += px

    with open(dst, "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (w, h))
        f.write(bytes(out))
    print(f"ditulis {dst}: {w}x{h}, {len(out)} byte piksel")
    return 0


if __name__ == "__main__":
    sys.exit(main())
