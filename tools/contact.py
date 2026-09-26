#!/usr/bin/env python3
"""Where each strike's limb really meets a body: for every frame of an attack clip, the largest
root-to-root distance (the victim straight ahead, facing the attacker) at which the striking limb's
part touches the victim's body parts (torso, head, arms) - exact box geometry from R6 forward
kinematics. Used to set each strike's contact distance (CombatConfig Ideal) and to check the hitbox."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anim import SIZES, Pack  # noqa: E402

CLIP = {"Swing1": "Swing1", "Swing2": "Swing2", "Swing3": "Swing3", "Uppercut": "Uppercut", "Sweep": "Sweeping Kick", "DashAttack": "Forward Dash Hit"}
LIMBS = {"Swing1": ["Right Arm"], "Swing2": ["Left Arm"], "Swing3": ["Right Arm", "Left Arm"], "Uppercut": ["Left Arm"], "Sweep": ["Right Leg"], "DashAttack": ["Right Arm"]}
BODY = ["Torso", "Head", "Right Arm", "Left Arm", "Right Leg", "Left Leg"]


def surface_points(m, size, n=5):
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    pts = []
    g = np.linspace(-1, 1, n)
    for a in g:
        for b in g:
            for face in ((1, a, b), (-1, a, b), (a, 1, b), (a, -1, b), (a, b, 1), (a, b, -1)):
                pts.append((face[0] * hx, face[1] * hy, face[2] * hz, 1.0))
    P = np.array(pts).T
    return (m @ P)[:3].T


def point_obb(p, m, size):
    inv = np.linalg.inv(m)
    q = (inv @ np.append(p, 1.0))[:3]
    h = np.array(size) / 2
    d = np.maximum(np.abs(q) - h, 0)
    return float(np.linalg.norm(d))


def victim_frame(D):
    # victim root at (0, 0, -D), facing +Z (toward the attacker)
    m = np.eye(4)
    m[0, 0], m[2, 2] = -1, -1
    m[2, 3] = -D
    return m


def gap(att_parts, limbs, vic_parts, D, vic_list=BODY):
    vf = victim_frame(D)
    best = 1e9
    for limb in limbs:
        pts = surface_points(att_parts[limb], SIZES[limb])
        for vp in vic_list:
            vm = vf @ vic_parts[vp]
            for p in pts:
                best = min(best, point_obb(p, vm, SIZES[vp]))
                if best <= 0:
                    return 0.0
    return best


def touch_distance(att_parts, limbs, vic_parts, vic_list=BODY):
    """the farthest root-to-root distance at which the limb touches (scan in, then refine)"""
    D = 7.0
    if gap(att_parts, limbs, vic_parts, D, vic_list) <= 1e-3:
        return D
    while D > 0.6:
        nd = D - 0.1
        if gap(att_parts, limbs, vic_parts, nd, vic_list) <= 1e-3:
            lo, hi = nd, D
            for _ in range(8):
                mid = (lo + hi) / 2
                if gap(att_parts, limbs, vic_parts, mid, vic_list) <= 1e-3:
                    lo = mid
                else:
                    hi = mid
            return lo
        D = nd
    return None


if __name__ == "__main__":
    pack = Pack(sys.argv[1] if len(sys.argv) > 1 else "Overkill_premium_polish_v46.rbxl")
    idle = pack.clip("Idle").parts(0.0)
    react = pack.clip("GettingHit1").parts(0.15)
    only = sys.argv[2:] or list(CLIP)
    for name in only:
        clip = pack.clip(CLIP[name])
        hit = [t for t, n, _ in clip.markers if n == "Hit"]
        print("%s  (Hit marker %s, len %.3f)" % (name, hit, clip.length))
        for t in np.arange(0.0, clip.length + 1e-6, 1 / 60):
            parts = clip.parts(t)
            d_idle = touch_distance(parts, LIMBS[name], idle)
            d_react = touch_distance(parts, LIMBS[name], react)
            d_torso = touch_distance(parts, LIMBS[name], idle, ["Torso", "Head"])
            if d_idle and d_idle > 2.2:
                print("   t %.3f  touch idle %.2f  torso/head %s  reacting %s" % (t, d_idle, "%.2f" % d_torso if d_torso else "-", "%.2f" % d_react if d_react else "-"))
