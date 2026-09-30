#!/usr/bin/env python3
"""Renders a heightmap dump (from tests/render_heights.luau) as a shaded relief PNG. Test/debug helper."""
import sys
import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
rows = [l.split() for l in open(src) if l[0] != "#"]
xs = np.array([int(r[0]) for r in rows]); zs = np.array([int(r[1]) for r in rows])
top = np.array([int(r[2]) for r in rows]); floor = np.array([int(r[3]) for r in rows])
w, h = xs.max() - xs.min() + 1, zs.max() - zs.min() + 1
T = np.zeros((h, w)); F = np.zeros((h, w))
T[zs - zs.min(), xs - xs.min()] = top; F[zs - zs.min(), xs - xs.min()] = floor
img = np.zeros((h, w, 3), dtype=np.float32)
sea = 62
land = F > sea - 1
# land: green -> brown -> white by height; water: blue by depth
hh = np.clip((F - sea) / 180.0, 0, 1)
img[..., 0] = np.where(land, 60 + 190 * hh ** 1.3, 20)
img[..., 1] = np.where(land, 130 + 90 * hh - 60 * hh ** 2, 60 + np.clip((F - (sea - 60)) * 1.5, 0, 90))
img[..., 2] = np.where(land, 50 + 200 * hh ** 2, 110 + np.clip((F - (sea - 60)) * 2.5, 0, 140))
# hillshade
gy, gx = np.gradient(F)
shade = np.clip(0.75 + (gx - gy) * 0.06, 0.4, 1.3)
img *= shade[..., None]
img = np.clip(img, 0, 255).astype(np.uint8)
scale = 6
Image.fromarray(img).resize((w * scale, h * scale), Image.NEAREST).save(dst)
print(dst, w * scale, h * scale, "land%:", round(100 * land.mean(), 1), "max floor", int(F.max()), "min", int(F.min()))
