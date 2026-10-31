#!/usr/bin/env python3
"""
把一张方形图标源图，加工成符合 macOS 图标栅格的母版 PNG（1024 画布 / 824 图标体）。

两种模式：

  ① 默认（源图自带底板）：源图是一块画好的圆角方块（例如蓝色底 + 白色图案）。
     从四角泛洪把**底板外的纯白**抠成透明，保留底板自身圆角与描边。
     不硬切圆角矩形——Apple 的连续圆角不是正圆弧，硬切会啃掉对角。

  ② `--tile`（源图是透明底的纯图案）：把图案抠出来，重新摆到一块白色圆角底板上。
     透明底的图案直接当图标会"飘"在 Dock 里（四个圆环中间透出壁纸，缩小后糊成一团）。

  ③ `--keep-tile`（源图已经自带圆角底板）：只按 macOS 栅格重排，图案与圆角原样保留。
     设计稿自己带底板时用这个——**别再去套一层**，否则圆角半径会被强行换成
     Apple 的 22.37%，跟设计稿对不上。

用法：
  python3 tools/prepare-icon.py <源图> <输出 PNG> [--tile | --keep-tile]
"""

import sys
from collections import deque
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
BODY = 824          # macOS 图标体在 1024 画布里的标准边长
WHITE_MIN = 250     # 泛洪的"这算背景"阈值
CORNER_RATIO = 0.2237   # macOS 图标圆角半径 ≈ 图标体边长的 22.37%
GLYPH_RATIO = 0.90      # --tile 模式下图案占底板的比例（用户要求"主体占九成"）


def is_background(pixel):
    return pixel[0] >= WHITE_MIN and pixel[1] >= WHITE_MIN and pixel[2] >= WHITE_MIN


def find_body_box(image):
    width, height = image.size
    pixels = image.load()
    left, top, right, bottom = width, height, -1, -1
    for y in range(height):
        for x in range(width):
            if not is_background(pixels[x, y]):
                left = min(left, x)
                right = max(right, x)
                break
        for x in range(width - 1, -1, -1):
            if not is_background(pixels[x, y]):
                left = min(left, x)
                right = max(right, x)
                break
    if right < 0:
        raise SystemExit("没找到图标主体：整张图都是白的")
    return left, top, right, bottom


def knock_out_corners(image):
    """从四角泛洪，只把与边缘连通的纯白变成透明。"""
    width, height = image.size
    pixels = image.load()
    background = bytearray(width * height)
    queue = deque()

    for x in range(width):
        for y in (0, height - 1):
            if is_background(pixels[x, y]):
                queue.append((x, y))
                background[y * width + x] = 1
    for y in range(height):
        for x in (0, width - 1):
            if is_background(pixels[x, y]):
                queue.append((x, y))
                background[y * width + x] = 1

    while queue:
        x, y = queue.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height and not background[ny * width + nx]:
                if is_background(pixels[nx, ny]):
                    background[ny * width + nx] = 1
                    queue.append((nx, ny))

    alpha = Image.new("L", (width, height), 255)
    alpha_pixels = alpha.load()
    for y in range(height):
        row = y * width
        for x in range(width):
            if background[row + x]:
                alpha_pixels[x, y] = 0
    # 轻微羽化：硬边在深色背景上会有锯齿
    return alpha.filter(ImageFilter.GaussianBlur(0.6))


def rounded_tile(size, color):
    """白色圆角底板。8 倍超采样再缩回来，边缘才没有锯齿。"""
    scale = 8
    big = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(big)
    radius = round(size * CORNER_RATIO) * scale
    draw.rounded_rectangle([0, 0, size * scale - 1, size * scale - 1],
                           radius=radius, fill=255)
    mask = big.resize((size, size), Image.LANCZOS)
    tile = Image.new("RGBA", (size, size), color + (255,))
    tile.putalpha(mask)
    return tile


def build_from_transparent(source, output):
    """源图是透明底的纯图案：抠出图案，摆到白色圆角底板上。"""
    image = Image.open(source).convert("RGBA")
    bbox = image.split()[3].getbbox()
    if not bbox:
        raise SystemExit("没找到图案：整张图都是透明的")

    # 裁到图案边界，再补成正方形（保持比例，居中）
    glyph = image.crop(bbox)
    side = max(glyph.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(glyph, ((side - glyph.size[0]) // 2, (side - glyph.size[1]) // 2), glyph)

    target = round(BODY * GLYPH_RATIO)
    square = square.resize((target, target), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    tile = rounded_tile(BODY, (255, 255, 255))
    tile_offset = (CANVAS - BODY) // 2
    canvas.paste(tile, (tile_offset, tile_offset), tile)
    glyph_offset = (CANVAS - target) // 2
    canvas.paste(square, (glyph_offset, glyph_offset), square)
    canvas.save(output)

    print(f"源图 {image.size} → 图案 {side}px → 底板 {BODY} 圆角 {round(BODY * CORNER_RATIO)}"
          f" → 图案占 {int(GLYPH_RATIO * 100)}%")
    print(f"已写出 {output}")


def build_keep_tile(source, output):
    """源图自带圆角底板：裁掉画布留白，整块底板缩到 824，居中放到 1024 画布。

    图案比例、圆角半径全部沿用设计稿，这里只做"对齐栅格"这一件事。
    """
    image = Image.open(source).convert("RGBA")
    bbox = image.split()[3].getbbox()
    if not bbox:
        raise SystemExit("没找到底板：整张图都是透明的")

    tile = image.crop(bbox)
    side = max(tile.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(tile, ((side - tile.size[0]) // 2, (side - tile.size[1]) // 2), tile)

    body = square.resize((BODY, BODY), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    canvas.paste(body, (offset, offset), body)
    canvas.save(output)

    print(f"源图 {image.size} → 底板 {side}px → 图标体 {BODY}（圆角、图案比例沿用设计稿）")
    print(f"已写出 {output}")


def main():
    args = [item for item in sys.argv[1:] if not item.startswith("--")]
    flags = {item for item in sys.argv[1:] if item.startswith("--")}
    if len(args) < 2:
        raise SystemExit("用法：prepare-icon.py <源图> <输出 PNG> [--tile | --keep-tile]")
    source, output = args[0], args[1]

    if "--keep-tile" in flags:
        build_keep_tile(source, output)
        return

    if "--tile" in flags:
        build_from_transparent(source, output)
        return

    image = Image.open(source).convert("RGB")
    left, top, right, bottom = find_body_box(image)
    side = max(right - left + 1, bottom - top + 1)

    # 裁成正方形（以方块中心为基准，多留的部分给透明边）
    cx, cy = (left + right) / 2, (top + bottom) / 2
    half = side / 2
    box = (round(cx - half), round(cy - half), round(cx + half), round(cy + half))
    cropped = image.crop(box)

    alpha = knock_out_corners(cropped)
    cropped = cropped.convert("RGBA")
    cropped.putalpha(alpha)

    body = cropped.resize((BODY, BODY), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    canvas.paste(body, (offset, offset), body)
    canvas.save(output)

    print(f"源图 {image.size} → 方块 {side}px → 母版 {CANVAS}×{CANVAS}（图标体 {BODY}）")
    print(f"已写出 {output}")


if __name__ == "__main__":
    main()
