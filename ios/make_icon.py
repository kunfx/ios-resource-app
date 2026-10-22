"""生成 1024x1024 App 图标（纯标准库，无需 Pillow）。"""
import struct
import zlib
import math
import os

S = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "Sources", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")

# 品牌渐变：翠绿 -> 青蓝
C1 = (16, 185, 129)
C2 = (6, 182, 212)

def lerp(a, b, t):
    return a + (b - a) * t

def grad_color(t):
    t = max(0.0, min(1.0, t))
    return (lerp(C1[0], C2[0], t), lerp(C1[1], C2[1], t), lerp(C1[2], C2[2], t))

def rounded_rect_cov(x, y, x0, y0, x1, y1, r):
    """返回点是否在圆角矩形内。"""
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

def in_triangle(x, y, p1, p2, p3):
    def sign(a, b, c):
        return (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1])
    d1 = sign((x, y), p1, p2)
    d2 = sign((x, y), p2, p3)
    d3 = sign((x, y), p3, p1)
    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (has_neg and has_pos)

# 图形：向下箭头 + 底座
BAR = (S * 0.5 - 62, S * 0.235, S * 0.5 + 62, S * 0.505)
TRI = ((S * 0.5, S * 0.705), (S * 0.5 - 196, S * 0.505), (S * 0.5 + 196, S * 0.505))
BASE = (S * 0.5 - 250, S * 0.775, S * 0.5 + 250, S * 0.845)

rows = []
SS = 2  # 2x2 超采样抗锯齿
for py in range(S):
    row = bytearray()
    for px in range(S):
        cov = 0
        for sy in range(SS):
            for sx in range(SS):
                x = px + (sx + 0.5) / SS
                y = py + (sy + 0.5) / SS
                hit = (
                    rounded_rect_cov(x, y, BAR[0], BAR[1], BAR[2], BAR[3], 62)
                    or in_triangle(x, y, *TRI)
                    or rounded_rect_cov(x, y, BASE[0], BASE[1], BASE[2], BASE[3], 36)
                )
                if hit:
                    cov += 1
        alpha = cov / (SS * SS)

        t = ((px / S) * 0.55 + (py / S) * 0.45)
        r, g, b = grad_color(t)

        # 左上角加一点柔光
        d = math.hypot(px - S * 0.18, py - S * 0.12) / (S * 0.75)
        glow = max(0.0, 1.0 - d) ** 2 * 0.28
        r = lerp(r, 255, glow)
        g = lerp(g, 255, glow)
        b = lerp(b, 255, glow)

        if alpha > 0:
            r = lerp(r, 255, alpha)
            g = lerp(g, 255, alpha)
            b = lerp(b, 255, alpha)

        row += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5)))
    rows.append(bytes(row))

raw = b"".join(b"\x00" + r for r in rows)

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "wb") as f:
    f.write(png)

print("written", OUT, len(png), "bytes")
