#!/usr/bin/env python3
"""Draw fighters (R6 boxes from tools/anim.py) to images, to look at the choreography:
side view, top view and a three-quarter view, painter-sorted and shaded.

    from render import Scene
    s = Scene()
    s.body(world_parts, color=(90,150,255), highlight={"Right Arm"})
    s.save("frame.png", title="Swing1 hit")
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from anim import SIZES

FACES = [
    ((1, 0, 0), [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)]),
    ((-1, 0, 0), [(-1, -1, 1), (-1, 1, 1), (-1, 1, -1), (-1, -1, -1)]),
    ((0, 1, 0), [(-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)]),
    ((0, -1, 0), [(-1, -1, 1), (-1, -1, -1), (1, -1, -1), (1, -1, 1)]),
    ((0, 0, 1), [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
    ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
]


def look_rot(yaw, pitch):
    cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    return rx @ ry


VIEWS = {
    "side": look_rot(math.radians(-90), 0),  # looking from +X toward -X: Z runs left-right
    "top": look_rot(0, math.radians(90)),
    "3/4": look_rot(math.radians(-50), math.radians(22)),
}


class Scene:
    def __init__(self, views=("side", "top", "3/4"), size=360, scale=34.0, center=(0, 0, -1.8)):
        self.views = views
        self.size = size
        self.scale = scale
        self.center = np.array(center, dtype=float)
        self.quads = []  # (world corners 4x3, normal, color)
        self.lines = []  # (a, b, color)
        self.labels = []

    def body(self, parts, color, highlight=(), skip=("HumanoidRootPart",), alpha=1.0):
        for name, m in parts.items():
            if name in skip:
                continue
            sx, sy, sz = SIZES[name]
            c = (255, 214, 64) if name in highlight else color
            for n, corners in FACES:
                pts = [(m @ np.array([cx * sx / 2, cy * sy / 2, cz * sz / 2, 1]))[:3] for cx, cy, cz in corners]
                nw = m[:3, :3] @ np.array(n, dtype=float)
                self.quads.append((np.array(pts), nw, c))

    def line(self, a, b, color=(255, 255, 255)):
        self.lines.append((np.array(a, float), np.array(b, float), color))

    def ground(self, y=-3.0, extent=6):
        for i in range(-extent, extent + 1):
            self.line((i, y, -extent + self.center[2]), (i, y, extent + self.center[2]), (60, 64, 76))
            self.line((-extent, y, i + self.center[2]), (extent, y, i + self.center[2]), (60, 64, 76))

    def _render(self, rot):
        img = Image.new("RGB", (self.size, self.size), (22, 26, 36))
        d = ImageDraw.Draw(img)
        light = np.array([0.4, 0.8, 0.45])
        light /= np.linalg.norm(light)

        def proj(p):
            q = rot @ (p - self.center)
            return (self.size / 2 + q[0] * self.scale, self.size / 2 - q[1] * self.scale), q[2]

        for a, b, c in self.lines:
            pa, _ = proj(a)
            pb, _ = proj(b)
            d.line([pa, pb], fill=c, width=1)
        items = []
        for pts, n, c in self.quads:
            vn = rot @ n
            if vn[2] < -1e-6:  # facing away (camera looks down -Z of the view)
                continue
            scr = [proj(p) for p in pts]
            depth = sum(z for _, z in scr) / 4
            shade = 0.45 + 0.55 * max(0.0, float(np.dot(n, light)))
            col = tuple(int(min(255, ch * shade)) for ch in c)
            items.append((depth, [s for s, _ in scr], col))
        items.sort(key=lambda x: x[0])
        for _, poly, col in items:
            d.polygon(poly, fill=col, outline=(10, 12, 18))
        return img

    def image(self, title=None):
        panels = [self._render(VIEWS[v]) for v in self.views]
        w = self.size * len(panels)
        out = Image.new("RGB", (w, self.size + 22), (14, 16, 22))
        for i, p in enumerate(panels):
            out.paste(p, (i * self.size, 22))
        d = ImageDraw.Draw(out)
        if title:
            d.text((6, 4), title, fill=(230, 230, 230))
        for i, v in enumerate(self.views):
            d.text((i * self.size + self.size - 40, 4), v, fill=(150, 150, 170))
        return out

    def save(self, path, title=None):
        self.image(title).save(path)


def sheet(images, cols, path):
    w, h = images[0].size
    rows = (len(images) + cols - 1) // cols
    out = Image.new("RGB", (w * cols, h * rows), (0, 0, 0))
    for i, im in enumerate(images):
        out.paste(im, ((i % cols) * w, (i // cols) * h))
    out.save(path)
