#!/usr/bin/env python3
"""Konversi NV12 (keluaran rkisp_mainpath) ke PPM RGB.

NV12: plane Y berukuran w*h, disusul plane CbCr terjalin berukuran w*h/2
(subsampling 4:2:0 -- satu pasang CbCr untuk tiap blok 2x2 piksel).

ISP melaporkan colorspace smpte170m (BT.601) dengan quantization full-range,
jadi tidak perlu penskalaan 16-235.

Pakai: python3 nv12_to_ppm.py in.yuv out.ppm <width> <height> [awb]

Argumen `awb` opsional mengaktifkan koreksi white balance grey-world: pusat
kroma digeser ke netral. Diperlukan karena tanpa daemon rkaiq, ISP memakai
gain WB default dan hasilnya biasanya bercast hijau.
"""
import sys

import numpy as np


def main():
    if len(sys.argv) not in (5, 6):
        print(__doc__)
        return 1
    src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    awb = len(sys.argv) == 6 and sys.argv[5].lower() == "awb"

    data = np.fromfile(src, dtype=np.uint8)
    need = w * h * 3 // 2
    if data.size < need:
        print(f"data kurang: {data.size} < {need}")
        return 1

    y = data[: w * h].reshape(h, w).astype(np.float32)
    uv = data[w * h : need].reshape(h // 2, w // 2, 2).astype(np.float32)

    # upsample kroma 2x (nearest -- cukup untuk pratinjau)
    u = np.repeat(np.repeat(uv[:, :, 0], 2, axis=0), 2, axis=1) - 128.0
    v = np.repeat(np.repeat(uv[:, :, 1], 2, axis=0), 2, axis=1) - 128.0

    print(f"kroma sebelum: U rata2 {u.mean():+.1f}  V rata2 {v.mean():+.1f}  (0 = netral)")
    if awb:
        # grey-world di domain kroma: geser pusat U dan V ke nol.
        # Lebih bersih daripada mengalikan kanal RGB karena luma tidak tersentuh.
        u = u - u.mean()
        v = v - v.mean()
        print("koreksi AWB grey-world diterapkan")

    r = y + 1.402 * v
    g = y - 0.344136 * u - 0.714136 * v
    b = y + 1.772 * u

    rgb = np.stack([r, g, b], axis=-1)
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)

    print(f"luma  min {y.min():.0f} max {y.max():.0f} rata2 {y.mean():.1f}")

    with open(dst, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(rgb.tobytes())
    print(f"ditulis {dst}: {w}x{h} RGB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
