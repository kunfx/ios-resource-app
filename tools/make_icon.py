import zlib, struct, math

W = H = 1024
SS = 2  # 2x2 supersampling

def lerp(a, b, t):
    return a + (b - a) * t

def in_round_rect(px, py, x0, y0, x1, y1, r):
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r

def sign(px, py, ax, ay, bx, by):
    return (px - bx) * (ay - by) - (ax - bx) * (py - by)

def in_triangle(px, py, ax, ay, bx, by, cx, cy):
    d1 = sign(px, py, ax, ay, bx, by)
    d2 = sign(px, py, bx, by, cx, cy)
    d3 = sign(px, py, cx, cy, ax, ay)
    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (has_neg and has_pos)

def in_circle(px, py, cx, cy, r):
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r

# bubble geometry
BX0, BY0, BX1, BY1, BR = 212.0, 248.0, 812.0, 700.0, 132.0
# tail triangle
T1 = (296.0, 672.0); T2 = (296.0, 812.0); T3 = (452.0, 686.0)
DOTS = [(392.0, 474.0), (512.0, 474.0), (632.0, 474.0)]
DR = 36.0

top = (0x33, 0x72, 0xF2)
bottom = (0x1B, 0x4C, 0xD2)
dot_color = (0x22, 0x5C, 0xDF)

rows = []
step = 1.0 / SS
offset = step / 2.0

for y in range(H):
    row = bytearray()
    for x in range(W):
        cov = 0
        for sy in range(SS):
            py = y + offset + sy * step
            for sx in range(SS):
                px = x + offset + sx * step
                solid = in_round_rect(px, py, BX0, BY0, BX1, BY1, BR) or in_triangle(px, py, *T1, *T2, *T3)
                if not solid:
                    continue
                in_dot = False
                for (cx, cy) in DOTS:
                    if in_circle(px, py, cx, cy, DR):
                        in_dot = True
                        break
                if not in_dot:
                    cov += 1
        t = y / (H - 1)
        bg = (lerp(top[0], bottom[0], t), lerp(top[1], bottom[1], t), lerp(top[2], bottom[2], t))
        a = cov / (SS * SS)
        r = int(round(bg[0] * (1 - a) + 255 * a))
        g = int(round(bg[1] * (1 - a) + 255 * a))
        b = int(round(bg[2] * (1 - a) + 255 * a))
        row += bytes((min(255, r), min(255, g), min(255, b)))
    rows.append(bytes(row))

raw = b"".join(b"\x00" + r for r in rows)

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, 9))
png += chunk(b"IEND", b"")

path = r"F:\网站备份\原创GO在线客服系统\ios-app\IfengAdmin\Assets.xcassets\AppIcon.appiconset\icon-1024.png"
with open(path, "wb") as f:
    f.write(png)
print("written", len(png))
