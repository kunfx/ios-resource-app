#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 AppIcon（1024×1024 PNG）。

为什么不用 Pillow：
    GitHub Actions 的 macOS runner 与本地环境都不保证装了 Pillow，
    这里只用标准库 zlib + struct 手写 PNG，任何 Python 3 都能跑。

图形说明：
    蓝色圆角方块 + 白色对话气泡 + 三个蓝点，与 APP 内 BrandMark 一致。
    不依赖任何外部素材，图标随时可重新生成。

用法：
    python3 tools/make_icon.py
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib

SIZE = 1024
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "IfengAdmin",
    "Assets.xcassets",
    "AppIcon.appiconset",
    "icon-1024.png",
)

# 品牌蓝，与 Theme.accent / Assets AccentColor 保持一致。
ACCENT_TOP = (58, 133, 246)
ACCENT_BOTTOM = (24, 92, 214)
WHITE = (255, 255, 255)


# ---------------------------------------------------------------- PNG 写入


def write_png(path: str, width: int, height: int, pixels: bytearray) -> None:
    """pixels 为 RGB 连续字节（无 alpha），写入 8bit truecolor PNG。"""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    # 每行前加 filter byte 0（None）。
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * stride : (y + 1) * stride])

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    body = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(body)


# ---------------------------------------------------------------- 绘图工具


class Canvas:
    def __init__(self, width: int, height: int) -> None:
        self.width = width
        self.height = height
        self.buffer = bytearray(width * height * 3)

    def put(self, x: int, y: int, color: tuple[int, int, int], alpha: float = 1.0) -> None:
        if alpha <= 0 or x < 0 or y < 0 or x >= self.width or y >= self.height:
            return
        index = (y * self.width + x) * 3
        if alpha >= 1.0:
            self.buffer[index] = color[0]
            self.buffer[index + 1] = color[1]
            self.buffer[index + 2] = color[2]
            return
        inverse = 1.0 - alpha
        self.buffer[index] = int(color[0] * alpha + self.buffer[index] * inverse)
        self.buffer[index + 1] = int(color[1] * alpha + self.buffer[index + 1] * inverse)
        self.buffer[index + 2] = int(color[2] * alpha + self.buffer[index + 2] * inverse)

    def fill_vertical_gradient(
        self, top: tuple[int, int, int], bottom: tuple[int, int, int]
    ) -> None:
        for y in range(self.height):
            ratio = y / max(1, self.height - 1)
            color = (
                int(top[0] + (bottom[0] - top[0]) * ratio),
                int(top[1] + (bottom[1] - top[1]) * ratio),
                int(top[2] + (bottom[2] - top[2]) * ratio),
            )
            for x in range(self.width):
                self.put(x, y, color)

    def rounded_rect(
        self,
        left: float,
        top: float,
        right: float,
        bottom: float,
        radius: float,
        color: tuple[int, int, int],
        alpha: float = 1.0,
    ) -> None:
        """带 2×2 超采样的圆角矩形，边缘不锯齿。"""
        for y in range(int(top) - 1, int(bottom) + 2):
            for x in range(int(left) - 1, int(right) + 2):
                coverage = 0
                for sub_y in (0.25, 0.75):
                    for sub_x in (0.25, 0.75):
                        if _inside_rounded(x + sub_x, y + sub_y, left, top, right, bottom, radius):
                            coverage += 1
                if coverage:
                    self.put(x, y, color, alpha * coverage / 4.0)

    def disc(
        self,
        center_x: float,
        center_y: float,
        radius: float,
        color: tuple[int, int, int],
        alpha: float = 1.0,
    ) -> None:
        self.rounded_rect(
            center_x - radius,
            center_y - radius,
            center_x + radius,
            center_y + radius,
            radius,
            color,
            alpha,
        )

    def triangle(
        self,
        points: list[tuple[float, float]],
        color: tuple[int, int, int],
        alpha: float = 1.0,
    ) -> None:
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        for y in range(int(min(ys)) - 1, int(max(ys)) + 2):
            for x in range(int(min(xs)) - 1, int(max(xs)) + 2):
                coverage = 0
                for sub_y in (0.25, 0.75):
                    for sub_x in (0.25, 0.75):
                        if _inside_triangle(x + sub_x, y + sub_y, points):
                            coverage += 1
                if coverage:
                    self.put(x, y, color, alpha * coverage / 4.0)


def _inside_rounded(
    x: float, y: float, left: float, top: float, right: float, bottom: float, radius: float
) -> bool:
    if x < left or x > right or y < top or y > bottom:
        return False
    inner_left = left + radius
    inner_right = right - radius
    inner_top = top + radius
    inner_bottom = bottom - radius
    if inner_left <= x <= inner_right or inner_top <= y <= inner_bottom:
        return True
    corner_x = inner_left if x < inner_left else inner_right
    corner_y = inner_top if y < inner_top else inner_bottom
    return (x - corner_x) ** 2 + (y - corner_y) ** 2 <= radius * radius


def _inside_triangle(x: float, y: float, points: list[tuple[float, float]]) -> bool:
    def sign(ax, ay, bx, by, cx, cy):
        return (ax - cx) * (by - cy) - (bx - cx) * (ay - cy)

    d1 = sign(x, y, points[0][0], points[0][1], points[1][0], points[1][1])
    d2 = sign(x, y, points[1][0], points[1][1], points[2][0], points[2][1])
    d3 = sign(x, y, points[2][0], points[2][1], points[0][0], points[0][1])
    has_negative = d1 < 0 or d2 < 0 or d3 < 0
    has_positive = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_negative and has_positive)


# ---------------------------------------------------------------- 主流程


def build() -> None:
    canvas = Canvas(SIZE, SIZE)

    # iOS 会自己裁圆角，这里铺满整块画布，避免出现白边。
    canvas.fill_vertical_gradient(ACCENT_TOP, ACCENT_BOTTOM)

    # 顶部一层柔光，让纯色不呆板。
    for y in range(0, int(SIZE * 0.55)):
        ratio = 1.0 - y / (SIZE * 0.55)
        for x in range(SIZE):
            canvas.put(x, y, WHITE, 0.06 * ratio * ratio)

    # 对话气泡：圆角矩形 + 左下角尾巴。
    bubble_left = SIZE * 0.20
    bubble_right = SIZE * 0.80
    bubble_top = SIZE * 0.245
    bubble_bottom = SIZE * 0.685
    canvas.rounded_rect(
        bubble_left,
        bubble_top,
        bubble_right,
        bubble_bottom,
        SIZE * 0.115,
        WHITE,
    )
    canvas.triangle(
        [
            (SIZE * 0.285, bubble_bottom - SIZE * 0.045),
            (SIZE * 0.285, SIZE * 0.815),
            (SIZE * 0.455, bubble_bottom - SIZE * 0.045),
        ],
        WHITE,
    )

    # 三个点：中间那个略大，形成视觉焦点。
    center_y = (bubble_top + bubble_bottom) / 2
    for index, (offset, radius) in enumerate(
        ((-0.115, 0.0355), (0.0, 0.0425), (0.115, 0.0355))
    ):
        canvas.disc(
            SIZE * (0.5 + offset),
            center_y,
            SIZE * radius,
            ACCENT_BOTTOM,
        )

    write_png(OUT, SIZE, SIZE, canvas.buffer)
    print(f"已生成 {OUT}（{os.path.getsize(OUT)} 字节）")


if __name__ == "__main__":
    try:
        build()
    except Exception as error:  # noqa: BLE001
        print(f"生成图标失败：{error}", file=sys.stderr)
        raise
