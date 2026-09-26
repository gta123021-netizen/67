#!/usr/bin/env python3
"""Pose continuity between chained strikes: for every legal pair (A -> B), how far B's pose at clip
time tau is from A's pose at clip time h (sum over limbs of the distance between matching points,
root space). Used to choose each pair's handoff (h), entry (tau) and cross-fade."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anim import Pack, point

KEYPTS = {"Torso": [(0, 0.8, -0.5), (0, -0.8, -0.5), (0.9, 0.8, 0), (-0.9, 0.8, 0)], "Head": [(0, 0, -0.5)],
          "Right Arm": [(0, 0.8, 0), (0, -1, 0)], "Left Arm": [(0, 0.8, 0), (0, -1, 0)],
          "Right Leg": [(0, 0.8, 0), (0, -1, 0)], "Left Leg": [(0, 0.8, 0), (0, -1, 0)]}

def posevec(parts):
    return np.concatenate([point(parts[n], p) for n, pts in KEYPTS.items() for p in pts])

def dist(a, b):
    d = (a - b).reshape(-1, 3)
    return float(np.sqrt((d ** 2).sum(1)).mean())

CLIP = {"Swing1": "Swing1", "Swing2": "Swing2", "Swing3": "Swing3", "Uppercut": "Uppercut", "Sweep": "Sweeping Kick"}
HIT = {"Swing1": 0.3667, "Swing2": 0.3667, "Swing3": 0.3833, "Uppercut": 0.3833, "Sweep": 0.9}

def table(pack):
    cache = {}
    def pv(name, t):
        key = (name, round(t, 4))
        if key not in cache:
            cache[key] = posevec(pack.clip(CLIP[name]).parts(t))
        return cache[key]
    return pv

if __name__ == "__main__":
    pack = Pack(sys.argv[1] if len(sys.argv) > 1 else "Overkill_premium_polish_v46.rbxl")
    pv = table(pack)
    pairs = [("Swing1", "Swing2"), ("Swing2", "Swing3"), ("Swing3", "Sweep"), ("Swing1", "Uppercut"), ("Swing2", "Uppercut"),
             ("Swing3", "Uppercut"), ("Uppercut", "Swing1"), ("Uppercut", "Swing2"), ("Uppercut", "Swing3"), ("Uppercut", "Sweep")]
    for a, b in pairs:
        ha = HIT[a]
        la = pack.clip(CLIP[a]).length
        print(f"\n{a} -> {b}   (A hit {ha}, len {la:.3f}; B hit {HIT[b]})")
        hs = [round(ha + d, 4) for d in np.arange(0.02, la - ha + 1e-6, 0.0333)]
        taus = [round(x, 4) for x in np.arange(0, HIT[b] - 0.15, 0.0333)]
        print("   h\\tau " + " ".join(f"{t:5.2f}" for t in taus))
        for h in hs:
            row = [dist(pv(a, h), pv(b, t)) for t in taus]
            best = int(np.argmin(row))
            print(f"   {h:5.3f} " + " ".join(("*" if i == best else " ") + f"{v:4.2f}" for i, v in enumerate(row)))
