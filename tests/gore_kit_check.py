#!/usr/bin/env python3
"""The gore kit's measured places (CombatGore's KIT table) against the built place itself.

    python3 tests/gore_kit_check.py Overkill_premium_polish_v47.rbxl

CombatGore seats each kit piece on an NPC from numbers measured once from the uploaded models.
This re-measures them from the place (ReplicatedStorage.Combat.Gore) and fails if any KIT entry has
drifted: the stumps, neck and skull base against the kit's torso, the torn arm ends against where
an R6 arm hangs, and the smashed-jaw head against the head of the dummy it was modelled on
(ServerStorage.VFXLibrary/v.2). It also checks the jaw head carries its surface map and a skin tone.
"""
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import rbxl  # noqa: E402

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "ReplicatedStorage__Combat__CombatGore.lua")

# the kit's torso is modelled lying on its side (1 x 2 x 2: X is its depth, Z its width): its frame
# expressed in an R6 torso's (X right, Y up, Z back)
KIT_TO_R6 = np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]])

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok else "  -- " + detail))
    if not ok:
        failures += 1


def kit_table():
    src = open(SRC).read()
    out = {}
    for m in re.finditer(r"(\w+) = \{ (?:Name = \"([^\"]+)\", )?Pos = Vector3\.new\(([^)]*)\), Rot = rot\(\{ ([^}]*) \}\), Size = Vector3\.new\(([^)]*)\)", src):
        key, name, pos, rot, size = m.groups()
        out[key] = {
            "Name": name,
            "Pos": np.array([float(x) for x in pos.split(",")]),
            "Rot": np.array([float(x) for x in rot.split(",")]).reshape(3, 3),
            "Size": np.array([float(x) for x in size.split(",")]),
        }
    return out


def main():
    place = rbxl.Place(sys.argv[1])

    def frame(ref):
        cid = place.ref_class[ref]
        pos, m = rbxl.decode_prop(place, cid, "CFrame")[place.classes[cid]["refs"].index(ref)]
        return np.array(pos), np.array(m).reshape(3, 3)

    def size(ref):
        cid = place.ref_class[ref]
        return np.array(rbxl.decode_prop(place, cid, "size")[place.classes[cid]["refs"].index(ref)])

    kit_ref = place.find("ReplicatedStorage/Combat/Gore/GoreKit")
    jaw_ref = place.find("ReplicatedStorage/Combat/Gore/JawHead")
    check("ReplicatedStorage.Combat.Gore.GoreKit is in the place", kit_ref is not None)
    check("ReplicatedStorage.Combat.Gore.JawHead is in the place", jaw_ref is not None)
    if kit_ref is None or jaw_ref is None:
        return
    pieces = {place.names[k]: k for k in place.children.get(kit_ref, [])}
    KIT = kit_table()
    check("CombatGore's KIT table parsed (7 seated entries)", len(KIT) == 7, str(sorted(KIT)))
    tp, tm = frame(pieces["torso"])

    def in_r6(ref):
        pp, pm = frame(ref)
        return KIT_TO_R6 @ (tm.T @ (pp - tp)), KIT_TO_R6 @ (tm.T @ pm)

    # on the torso
    for key in ("RightStump", "LeftStump", "NeckStump", "SkullBase"):
        e = KIT[key]
        pos, rot = in_r6(pieces[e["Name"]])
        check("%s (%s): position" % (key, e["Name"]), np.allclose(pos, e["Pos"], atol=2e-3), "%s vs %s" % (pos.round(4), e["Pos"]))
        check("%s (%s): rotation" % (key, e["Name"]), np.allclose(rot, e["Rot"], atol=3e-3), "%s vs %s" % (rot.round(3).flatten(), e["Rot"].flatten()))
        check("%s (%s): size" % (key, e["Name"]), np.allclose(size(pieces[e["Name"]]), e["Size"], atol=2e-3), str(size(pieces[e["Name"]])))
    # the torn ends, against the arm they came off (an R6 arm hangs at (+-1.5, 0, 0) on the torso)
    for key, arm_x in (("RightEnd", 1.5), ("LeftEnd", -1.5)):
        e = KIT[key]
        pos, rot = in_r6(pieces[e["Name"]])
        pos = pos - np.array([arm_x, 0, 0])
        check("%s (%s): position on the arm" % (key, e["Name"]), np.allclose(pos, e["Pos"], atol=2e-3), "%s vs %s" % (pos.round(4), e["Pos"]))
        check("%s (%s): rotation" % (key, e["Name"]), np.allclose(rot, e["Rot"], atol=3e-3), "%s vs %s" % (rot.round(3).flatten(), e["Rot"].flatten()))
        check("%s (%s): size" % (key, e["Name"]), np.allclose(size(pieces[e["Name"]]), e["Size"], atol=2e-3), str(size(pieces[e["Name"]])))
    # the smashed-jaw head against the head of its dummy
    dummy_torso = place.find("ServerStorage/VFXLibrary/v.2/R6 [Dummy]/Torso")
    if dummy_torso is not None:
        dp, dm = frame(dummy_torso)
        jp, jm = frame(jaw_ref)
        head = dp + dm @ np.array([0, 1.5, 0])
        pos, rot = dm.T @ (jp - head), dm.T @ jm
        e = KIT["Jaw"]
        check("Jaw: position on the head", np.allclose(pos, e["Pos"], atol=2e-3), "%s vs %s" % (pos.round(4), e["Pos"]))
        check("Jaw: rotation", np.allclose(rot, e["Rot"], atol=3e-3), str(rot.round(3).flatten()))
        check("Jaw: size", np.allclose(size(jaw_ref), e["Size"], atol=2e-3), str(size(jaw_ref)))
    else:
        print("  (the v.2 dummy is not in this place: the jaw's seat is not re-measured)")
    # every seated rotation is proper (never a mirror)
    for key, e in KIT.items():
        r = e["Rot"]
        check("%s: a proper rotation" % key, np.allclose(r @ r.T, np.eye(3), atol=1e-6) and abs(np.linalg.det(r) - 1) < 1e-6)
    # the jaw head: skin-toned, its surface map kept
    kids = [place.class_name(k) for k in place.children.get(jaw_ref, [])]
    check("JawHead keeps its SurfaceAppearance (the wound, flesh and teeth)", "SurfaceAppearance" in kids)
    cid = place.ref_class[jaw_ref]
    col = rbxl.decode_prop(place, cid, "Color3uint8")[place.classes[cid]["refs"].index(jaw_ref)]
    check("JawHead is skin-toned, not the grey it came in", tuple(col) != (163, 162, 165) and col[0] > col[1] > col[2], str(col))
    check("the kit's torso (the hole) is in the kit but CombatGore never names it", "torso" in pieces and '"torso"' not in open(SRC).read())


if __name__ == "__main__":
    main()
    print("\n%s" % ("all passed" if failures == 0 else "%d FAILED" % failures))
    sys.exit(1 if failures else 0)
