#!/usr/bin/env python3
"""Uji unit demosaic: buat gambar RGB yang diketahui, mosaic ke BGGR,
demosaic kembali, lalu bandingkan. Kalau kodenya benar, hasilnya mendekati asli."""
import sys

import numpy as np

sys.path.insert(0, "/mnt/c/Users/apinb/luckfox/luckfox_pico_mini_B-Camera/scripts")
from demosaic import demosaic  # noqa

h, w = 64, 256
# bilah warna: putih, kuning, cyan, hijau, magenta, merah, biru, hitam
bars = [(1,1,1),(1,1,0),(0,1,1),(0,1,0),(1,0,1),(1,0,0),(0,0,1),(0,0,0)]
rgb = np.zeros((h, w, 3), dtype=np.float32)
bw = w // len(bars)
for i, c in enumerate(bars):
    rgb[:, i*bw:(i+1)*bw] = np.array(c, dtype=np.float32) * 900

# mosaic ke BGGR: B(0,0) G(0,1) G(1,0) R(1,1)
bayer = np.zeros((h, w), dtype=np.float32)
bayer[0::2, 0::2] = rgb[0::2, 0::2, 2]   # B
bayer[0::2, 1::2] = rgb[0::2, 1::2, 1]   # G
bayer[1::2, 0::2] = rgb[1::2, 0::2, 1]   # G
bayer[1::2, 1::2] = rgb[1::2, 1::2, 0]   # R

r, g, b = demosaic(bayer, "BGGR")
out = np.stack([r, g, b], axis=-1)

# bandingkan di tengah tiap bilah (hindari tepi)
print("bilah |  asli R,G,B  | hasil R,G,B")
ok = True
for i, c in enumerate(bars):
    x = i*bw + bw//2
    y = h//2
    exp = np.array(c, dtype=np.float32) * 900
    got = out[y, x]
    d = np.abs(exp - got).max()
    flag = "OK" if d < 60 else "BEDA"
    if d >= 60:
        ok = False
    print(f"  {i}   | {exp[0]:5.0f},{exp[1]:5.0f},{exp[2]:5.0f} | "
          f"{got[0]:5.0f},{got[1]:5.0f},{got[2]:5.0f}   selisih {d:5.0f}  {flag}")

print()
print("HASIL:", "demosaic BENAR" if ok else "demosaic BERMASALAH")
