#!/usr/bin/env python3
"""The animation pack's clips, straight from the place's KeyframeSequences, with R6 forward
kinematics: where every body part of a fighter is at any clip time (root space).

    from anim import Pack
    pack = Pack("Overkill_premium_polish_v46.rbxl")
    clip = pack.clip("Swing1")           # names: Swing1 Swing2 Swing3 Uppercut Sweeping Kick ...
    parts = clip.parts(0.3667)           # {"Torso": 4x4, "Right Arm": 4x4, ...} relative to the root
    clip.markers                         # [(time, name, value)]

Interpolation follows Roblox: each joint eases from the last keyframe that poses it to the next
one, with that pose's easing style / direction.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402


def cf(pos, rot=None):
    m = np.eye(4)
    if rot is not None:
        m[:3, :3] = np.array(rot, dtype=float).reshape(3, 3)
    m[:3, 3] = pos
    return m


def R(r00, r01, r02, r10, r11, r12, r20, r21, r22):
    return (r00, r01, r02, r10, r11, r12, r20, r21, r22)


# the standard R6 joints: (part1, part0, C0, C1)
JOINTS = [
    ("Torso", "HumanoidRootPart", cf((0, 0, 0), R(-1, 0, 0, 0, 0, 1, 0, 1, 0)), cf((0, 0, 0), R(-1, 0, 0, 0, 0, 1, 0, 1, 0))),
    ("Head", "Torso", cf((0, 1, 0), R(-1, 0, 0, 0, 0, 1, 0, 1, 0)), cf((0, -0.5, 0), R(-1, 0, 0, 0, 0, 1, 0, 1, 0))),
    ("Right Arm", "Torso", cf((1, 0.5, 0), R(0, 0, 1, 0, 1, 0, -1, 0, 0)), cf((-0.5, 0.5, 0), R(0, 0, 1, 0, 1, 0, -1, 0, 0))),
    ("Left Arm", "Torso", cf((-1, 0.5, 0), R(0, 0, -1, 0, 1, 0, 1, 0, 0)), cf((0.5, 0.5, 0), R(0, 0, -1, 0, 1, 0, 1, 0, 0))),
    ("Right Leg", "Torso", cf((1, -1, 0), R(0, 0, 1, 0, 1, 0, -1, 0, 0)), cf((0.5, 1, 0), R(0, 0, 1, 0, 1, 0, -1, 0, 0))),
    ("Left Leg", "Torso", cf((-1, -1, 0), R(0, 0, -1, 0, 1, 0, 1, 0, 0)), cf((-0.5, 1, 0), R(0, 0, -1, 0, 1, 0, 1, 0, 0))),
]
SIZES = {"HumanoidRootPart": (2, 2, 1), "Torso": (2, 2, 1), "Head": (2, 1, 1), "Right Arm": (1, 2, 1), "Left Arm": (1, 2, 1), "Right Leg": (1, 2, 1), "Left Leg": (1, 2, 1)}
LIMBS = ["Torso", "Head", "Right Arm", "Left Arm", "Right Leg", "Left Leg"]


def quat_from_matrix(m):
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        return np.array([0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s])
    if m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return np.array([(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s])
    if m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return np.array([(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s])
    s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return np.array([(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s])


def matrix_from_quat(q):
    w, x, y, z = q / np.linalg.norm(q)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def slerp(q0, q1, a):
    d = float(np.dot(q0, q1))
    if d < 0:
        q1, d = -q1, -d
    if d > 0.9995:
        q = q0 + (q1 - q0) * a
        return q / np.linalg.norm(q)
    th = math.acos(min(1.0, d))
    return (math.sin((1 - a) * th) * q0 + math.sin(a * th) * q1) / math.sin(th)


def lerp_cf(a, b, k):
    out = np.eye(4)
    out[:3, :3] = matrix_from_quat(slerp(quat_from_matrix(a[:3, :3]), quat_from_matrix(b[:3, :3]), k))
    out[:3, 3] = a[:3, 3] + (b[:3, 3] - a[:3, 3]) * k
    return out


def ease(style, direction, a):
    # PoseEasingStyle: 0 Linear, 1 Constant, 2 Elastic, 3 Cubic, 4 Bounce, 5 CubicV2
    # (legacy poses swap In and Out for Cubic / Elastic / Bounce: "In" reads as ease-out)
    if style == 1:
        return 0.0
    if style == 0:
        return a
    d = direction
    if style in (2, 3, 4):
        d = {0: 1, 1: 0, 2: 2}.get(direction, direction)
    if d == 0:  # In
        return a ** 3
    if d == 1:  # Out
        return 1 - (1 - a) ** 3
    return 4 * a ** 3 if a < 0.5 else 1 - (-2 * a + 2) ** 3 / 2


class Clip:
    def __init__(self, name, keyframes, markers, loop):
        self.name = name
        self.keyframes = keyframes  # [(time, {joint: (matrix, weight, style, dir)})]
        self.markers = markers
        self.loop = loop
        self.length = keyframes[-1][0] if keyframes else 0

    def transform(self, joint, t):
        prev = nxt = None
        for time, poses in self.keyframes:
            if joint in poses:
                if time <= t:
                    prev = (time, poses[joint])
                elif nxt is None:
                    nxt = (time, poses[joint])
        if prev is None and nxt is None:
            return np.eye(4)
        if prev is None:
            return nxt[1][0]
        if nxt is None:
            return prev[1][0]
        a = (t - prev[0]) / max(nxt[0] - prev[0], 1e-9)
        a = ease(prev[1][2], prev[1][3], max(0.0, min(1.0, a)))
        return lerp_cf(prev[1][0], nxt[1][0], a)

    def transforms(self, t):
        return {j[0]: self.transform(j[0], t) for j in JOINTS}

    def parts(self, t, transforms=None):
        tr = transforms or self.transforms(t)
        return fk(tr)


def fk(tr):
    world = {"HumanoidRootPart": np.eye(4)}
    for part1, part0, c0, c1 in JOINTS:
        world[part1] = world[part0] @ c0 @ tr.get(part1, np.eye(4)) @ np.linalg.inv(c1)
    return world


def blend_transforms(a, b, w):
    """a weighted toward b by w (a cross-fade between two clips' joint transforms)."""
    return {k: lerp_cf(a[k], b[k], w) for k in a}


class Pack:
    def __init__(self, place_path):
        p = rbxl.Place(place_path)
        self.place = p
        get = {}

        def prop(cls, name):
            key = (cls, name)
            if key not in get:
                vals = {}
                for cid, info in p.classes.items():
                    if info["name"] == cls:
                        v = rbxl.decode_prop(p, cid, name)
                        if v is not None:
                            for r, x in zip(info["refs"], v):
                                vals[r] = x
                get[key] = vals
            return get[key]

        self.clips = {}
        for cid, idx, ref in rbxl.instances_of(p, "KeyframeSequence"):
            path = p.path(ref)
            if "Katana" in "/".join(path):
                continue
            name = p.names.get(ref)
            kfs, markers = [], []
            for kref in p.children.get(ref, []):
                if p.class_name(kref) != "Keyframe":
                    continue
                time = prop("Keyframe", "Time")[kref]
                poses = {}

                def walk(r):
                    for c in p.children.get(r, []):
                        cls = p.class_name(c)
                        if cls == "Pose":
                            pos, rot = prop("Pose", "CFrame")[c]
                            poses[p.names.get(c)] = (
                                cf(pos, rot),
                                prop("Pose", "Weight").get(c, 1),
                                prop("Pose", "EasingStyle").get(c, 0),
                                prop("Pose", "EasingDirection").get(c, 0),
                            )
                            walk(c)
                        elif cls == "KeyframeMarker":
                            markers.append((time, p.names.get(c), prop("KeyframeMarker", "Value").get(c, "")))

                walk(kref)
                kfs.append((time, poses))
            kfs.sort(key=lambda x: x[0])
            markers.sort()
            loop = prop("KeyframeSequence", "Loop").get(ref, False)
            key = name if name not in self.clips else "/".join(path[-3:])
            self.clips[key] = Clip(name, kfs, markers, loop)

    def clip(self, name):
        return self.clips[name]


def point(m, local):
    return (m @ np.array([local[0], local[1], local[2], 1.0]))[:3]


if __name__ == "__main__":
    pack = Pack(sys.argv[1] if len(sys.argv) > 1 else "Overkill_premium_polish_v46.rbxl")
    for k, c in sorted(pack.clips.items()):
        print("%-22s len %.3f  keyframes %3d  loop %s  markers %s" % (k, c.length, len(c.keyframes), c.loop, [(round(t, 4), n) for t, n, _ in c.markers]))
