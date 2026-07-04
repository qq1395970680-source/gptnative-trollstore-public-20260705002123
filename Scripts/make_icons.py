import json
import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"


def chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def png_rgba(size: int) -> bytes:
    def capsule_distance(px, py, ax, ay, bx, by):
        abx = bx - ax
        aby = by - ay
        apx = px - ax
        apy = py - ay
        denom = abx * abx + aby * aby
        if denom == 0:
            return math.sqrt(apx * apx + apy * apy)
        t = max(0.0, min(1.0, (apx * abx + apy * aby) / denom))
        cx = ax + abx * t
        cy = ay + aby * t
        dx = px - cx
        dy = py - cy
        return math.sqrt(dx * dx + dy * dy)

    def smoothstep(edge0, edge1, x):
        if edge0 == edge1:
            return 1.0 if x >= edge1 else 0.0
        t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)

    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            nx = x / max(size - 1, 1)
            ny = y / max(size - 1, 1)
            cx = nx - 0.5
            cy = ny - 0.5
            dist = min(1.0, math.sqrt(cx * cx + cy * cy) * 1.7)

            r = int(8 + 15 * nx + 8 * (1 - dist))
            g = int(118 + 46 * (1 - ny) + 18 * (1 - dist))
            b = int(88 + 32 * ny + 12 * (1 - dist))

            px = nx - 0.5
            py = ny - 0.5
            min_mark_distance = 9.0
            for i in range(6):
                angle = (math.pi / 3.0) * i + math.pi / 6.0
                tangent = angle + math.pi / 2.0
                anchor_radius = 0.235
                half_len = 0.18
                ax = math.cos(angle) * anchor_radius - math.cos(tangent) * half_len
                ay = math.sin(angle) * anchor_radius - math.sin(tangent) * half_len
                bx = math.cos(angle) * anchor_radius + math.cos(tangent) * half_len
                by = math.sin(angle) * anchor_radius + math.sin(tangent) * half_len
                min_mark_distance = min(min_mark_distance, capsule_distance(px, py, ax, ay, bx, by))

            mark_alpha = 1.0 - smoothstep(0.055, 0.075, min_mark_distance)
            center_alpha = 1.0 - smoothstep(0.078, 0.095, math.sqrt(px * px + py * py))
            mark_alpha = max(mark_alpha, center_alpha * 0.95)

            if mark_alpha > 0:
                r = int(r * (1 - mark_alpha) + 248 * mark_alpha)
                g = int(g * (1 - mark_alpha) + 250 * mark_alpha)
                b = int(b * (1 - mark_alpha) + 248 * mark_alpha)

            row.extend([r, g, b, 255])
        rows.append(bytes(row))

    raw = b"".join(rows)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def write_icon(filename: str, size: int) -> None:
    (ICON_DIR / filename).write_bytes(png_rgba(size))


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)

    images = [
        {"idiom": "iphone", "size": "20x20", "scale": "2x", "filename": "Icon-20@2x.png", "pixels": 40},
        {"idiom": "iphone", "size": "20x20", "scale": "3x", "filename": "Icon-20@3x.png", "pixels": 60},
        {"idiom": "iphone", "size": "29x29", "scale": "2x", "filename": "Icon-29@2x.png", "pixels": 58},
        {"idiom": "iphone", "size": "29x29", "scale": "3x", "filename": "Icon-29@3x.png", "pixels": 87},
        {"idiom": "iphone", "size": "40x40", "scale": "2x", "filename": "Icon-40@2x.png", "pixels": 80},
        {"idiom": "iphone", "size": "40x40", "scale": "3x", "filename": "Icon-40@3x.png", "pixels": 120},
        {"idiom": "iphone", "size": "60x60", "scale": "2x", "filename": "Icon-60@2x.png", "pixels": 120},
        {"idiom": "iphone", "size": "60x60", "scale": "3x", "filename": "Icon-60@3x.png", "pixels": 180},
        {"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": "Icon-1024.png", "pixels": 1024},
    ]

    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    for image in images:
        write_icon(image["filename"], image.pop("pixels"))
        contents["images"].append(image)

    (ICON_DIR / "Contents.json").write_text(json.dumps(contents, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
