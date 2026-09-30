#!/usr/bin/env python3
"""Renders the dump from tests/render_surface.luau as a top-down map coloured by surface material."""
import sys
import numpy as np
from PIL import Image
sys.path.insert(0, ".")
src, dst = sys.argv[1], sys.argv[2]
names = ["air","stone","water","lava","deepslate","bedrock","granite","diorite","andesite","tuff","calcite","dirt","coarse_dirt","podzol","grass_block","mycelium","mud","sand","red_sand","sandstone","red_sandstone","gravel","clay","terracotta","orange_terracotta","yellow_terracotta","brown_terracotta","red_terracotta","white_terracotta","light_gray_terracotta","snow_block","powder_snow","ice","packed_ice","blue_ice","moss_block","magma_block"]
col = {"stone":(125,125,125),"water":(45,90,200),"lava":(230,110,20),"deepslate":(70,70,75),"granite":(150,100,85),"diorite":(200,200,200),"andesite":(135,135,135),"tuff":(105,108,100),"calcite":(235,235,230),
 "dirt":(130,95,65),"coarse_dirt":(115,85,60),"podzol":(90,65,40),"grass_block":(98,160,60),"mycelium":(110,95,110),"mud":(65,55,50),"sand":(219,207,163),"red_sand":(190,102,33),"sandstone":(216,203,152),
 "red_sandstone":(181,98,32),"gravel":(131,127,126),"clay":(160,166,178),"terracotta":(152,94,67),"orange_terracotta":(161,83,37),"yellow_terracotta":(186,133,35),"brown_terracotta":(77,51,35),"red_terracotta":(143,61,46),
 "white_terracotta":(209,177,161),"light_gray_terracotta":(135,106,97),"snow_block":(245,250,252),"powder_snow":(240,245,250),"ice":(150,190,250),"packed_ice":(130,170,240),"blue_ice":(110,150,255),"moss_block":(80,120,50),"bedrock":(30,30,30)}
rows = [l.split() for l in open(src) if l[0] != "#"]
xs = np.array([int(r[0]) for r in rows]); zs = np.array([int(r[1]) for r in rows])
top = np.array([int(r[2]) for r in rows]); floor = np.array([int(r[3]) for r in rows]); blk = np.array([int(r[4]) for r in rows]); fb = np.array([int(r[5]) for r in rows])
x0, z0 = xs.min(), zs.min()
w, h = (xs.max() - x0) // 2 + 1, (zs.max() - z0) // 2 + 1
img = np.zeros((h, w, 3), np.float32); F = np.zeros((h, w))
for i in range(len(rows)):
    ix, iz = (xs[i] - x0) // 2, (zs[i] - z0) // 2
    n = names[blk[i]]
    c = col.get(n, (255, 0, 255))
    if n in ("water", "ice"):  # show the seabed through the water, tinted
        s = np.array(col.get(names[fb[i]], (100, 100, 100)), np.float32)
        depth = max(0, 62 - floor[i])
        c = tuple(np.array(c, np.float32) * min(1, 0.45 + depth / 60) + s * 0.25 * max(0, 1 - depth / 40)) if n == "water" else c
    img[iz, ix] = c
    F[iz, ix] = floor[i]
gy, gx = np.gradient(F)
shade = np.clip(0.85 + (gx - gy) * 0.05, 0.6, 1.25)
img = np.clip(img * shade[..., None], 0, 255).astype(np.uint8)
Image.fromarray(img).resize((w * 4, h * 4), Image.NEAREST).save(dst)
print(dst, w * 4, h * 4)
from collections import Counter
print(Counter(names[b] for b in blk).most_common(12))
print(Counter(r[6] for r in rows).most_common(10))
