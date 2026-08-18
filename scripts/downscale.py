#!/usr/bin/env python3
"""Perkecil PPM dengan RATA-RATA blok, bukan point sampling.

Point sampling pada citra hasil demosaic Bayer menghasilkan aliasing berat:
fase Bayer berulang tiap 2 piksel, jadi mengambil tiap piksel ke-N memilih
fase yang sama terus-menerus dan memperkuat sisa artefak jadi noise kroma.
Rata-rata blok meratakannya.

Pakai: python3 downscale.py in.ppm out.ppm <faktor>
"""
import sys

import numpy as np


def main():
    src, dst, f = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(src, "rb") as fh:
        assert fh.readline().strip() == b"P6"
        w, h = map(int, fh.readline().split())
        fh.readline()
        img = np.frombuffer(fh.read(), dtype=np.uint8).reshape(h, w, 3).astype(np.float32)

    nh, nw = h // f, w // f
    img = img[: nh * f, : nw * f]
    small = img.reshape(nh, f, nw, f, 3).mean(axis=(1, 3))
    small = np.clip(small, 0, 255).astype(np.uint8)

    with open(dst, "wb") as fh:
        fh.write(b"P6\n%d %d\n255\n" % (nw, nh))
        fh.write(small.tobytes())
    print(f"{w}x{h} -> {nw}x{nh} (rata-rata blok {f}x{f})")


if __name__ == "__main__":
    main()
