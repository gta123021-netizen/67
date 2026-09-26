#!/usr/bin/env python3
"""Build Overkill v47 from the v46 place the user saved with the full VFX library.

    python3 tools/build_v47.py <v46 with VFX.rbxl> src <out.rbxl>

1. structure
   - HitDetect moves to ReplicatedStorage.Combat (the attacking client runs the same hit test)
   - new ModuleScripts: ReplicatedStorage.Combat.CombatChoreo, ReplicatedStorage.Combat.CombatBlood
   - the combat's effect templates are taken from the imported packs into
     ReplicatedStorage.Combat.VFX (see TEMPLATES)
   - everything else the import dropped into Workspace (133 packs, models and loose parts: live
     particle emitters and a dozen spinning demo scripts, in the middle of the map) moves into
     ServerStorage.VFXLibrary: kept in the place for later use, never rendered, never run,
     never sent to a client
2. sources: every script whose file in src/ differs gets the file's source (tools/build_rbxl.py)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402
from extract_rbxl import EXT, file_name  # noqa: E402

# the map's own Workspace children (everything else in Workspace came with the VFX import)
MAP = {("Camera", "Camera"), ("Terrain", "Terrain")}

# (pack path, attachment name inside it, template name, pick) - pick: a texture one of its emitters
# must use (two packs share a name)
TEMPLATES = [
    ("Workspace/Anime/Punch-03", "Main", "HitFlash", None),
    ("Workspace/Anime/Punch-01", "Main", "HitFlashHeavy", None),
    ("Workspace/Yona VFX Pack/Combat-VFX/Block", "Main", "BlockSparks", None),
    ("Workspace/Anime/Smoke-01", "Main", "DustPuff", "rbxassetid://16669188960"),
    ("Workspace/Yona VFX Pack/Explosion-VFX/Ground-Crack-01", "Main", "GroundCrack1", None),
    ("Workspace/Yona VFX Pack/Explosion-VFX/Ground-Crack-02", "Main", "GroundCrack2", None),
    ("Workspace/Anime/Crack-01", "Main", "FloorCrack", None),
    ("Workspace/Anime/Wind-01", "Main", "ShockRing", None),
    ("Workspace/Anime/Wind-02", "Main", "DustBurst", None),
]

NEW_MODULES = [("ReplicatedStorage/Combat", "CombatChoreo"), ("ReplicatedStorage/Combat", "CombatBlood")]


def find_all(p, path):
    parts = path.split("/")
    cur = [r for r in p.ref_class if p.parent.get(r, -1) == -1 and p.names.get(r) == parts[0]]
    for name in parts[1:]:
        cur = [k for c in cur for k in p.children.get(c, []) if p.names.get(k) == name]
    return cur


def emitter_textures(p, ref):
    out = set()
    for k in p.children.get(ref, []):
        if p.class_name(k) == "ParticleEmitter":
            cid = p.ref_class[k]
            vals = rbxl.decode_prop(p, cid, "Texture")
            if vals:
                out.add(vals[p.classes[cid]["refs"].index(k)])
    return out


def structure(p, old_workspace_children):
    combat = p.find("ReplicatedStorage/Combat")
    vfx = p.find("ReplicatedStorage/Combat/VFX")
    assert combat and vfx, "ReplicatedStorage.Combat.VFX missing"
    # HitDetect: shared
    hd = p.find("ServerScriptService/Combat/HitDetect")
    if hd:
        p.set_parent(hd, combat)
        print("moved HitDetect -> ReplicatedStorage.Combat")
    # new modules (a copy of an existing ModuleScript, renamed; the source comes from src/)
    template = p.find("ReplicatedStorage/Combat/Motion")
    for parent_path, name in NEW_MODULES:
        if p.find(parent_path + "/" + name):
            continue
        p.clone_instance(template, p.find(parent_path), name)
        print("new ModuleScript", parent_path + "/" + name)
    # effect templates
    for pack, att, name, pick in TEMPLATES:
        if p.find("ReplicatedStorage/Combat/VFX/" + name):
            continue
        found = None
        for ref in find_all(p, pack + "/" + att):
            if pick is None or pick in emitter_textures(p, ref):
                found = ref
                break
        if not found:
            print("template not found:", pack)
            continue
        p.set_parent(found, vfx)
        p.set_name(found, name)
        print("template", name, "<-", pack)
    # the rest of the import: out of the live world
    ws = p.find("Workspace")
    ss = p.find("ServerStorage")
    lib = p.find("ServerStorage/VFXLibrary")
    if not lib:
        folder_template = next(r for r in p.ref_class if p.class_name(r) == "Folder")
        lib = p.clone_instance(folder_template, ss, "VFXLibrary")
    moved = 0
    budget = dict(old_workspace_children)
    for r in list(p.children.get(ws, [])):
        key = (p.names.get(r), p.class_name(r))
        if budget.get(key, 0) > 0:
            budget[key] -= 1
            continue
        if key in MAP:
            continue
        p.set_parent(r, lib)
        moved += 1
    print("moved %d imported Workspace items -> ServerStorage.VFXLibrary" % moved)


def sources(p, src_dir):
    counts = {}
    for cid, info in p.classes.items():
        if info["name"] in EXT:
            for ref in info["refs"]:
                name = file_name(p.path(ref), info["name"])
                counts[name] = counts.get(name, 0) + 1
    changed, used = [], set()
    for cid, info in p.classes.items():
        if info["name"] not in EXT:
            continue
        srcs = p.get_strings(cid, "Source")
        dirty = False
        for i, ref in enumerate(info["refs"]):
            name = file_name(p.path(ref), info["name"])
            if counts[name] != 1:
                continue
            fp = os.path.join(src_dir, name)
            if not os.path.exists(fp):
                continue
            used.add(name)
            new = open(fp, "rb").read()
            if new != srcs[i]:
                srcs[i] = new
                dirty = True
                changed.append(name)
        if dirty:
            p.set_strings(cid, "Source", srcs)
    missing = sorted(n for n in os.listdir(src_dir) if n.endswith(".lua") and n not in used and counts.get(n, 0) <= 1)
    for n in missing:
        print("not in the place (skipped):", n)
    print("%d scripts changed" % len(changed))
    for n in sorted(changed):
        print("  " + n)
    return missing


def main():
    in_path, src_dir, out_path = sys.argv[1:4]
    base = sys.argv[4] if len(sys.argv) > 4 else "Overkill_premium_polish_v46.rbxl"
    # the map's own Workspace children, from the v46 before the import
    old = rbxl.Place(base)
    ows = old.find("Workspace")
    old_children = {}
    for r in old.children.get(ows, []):
        key = (old.names.get(r), old.class_name(r))
        old_children[key] = old_children.get(key, 0) + 1
    p = rbxl.Place(in_path)
    structure(p, old_children)
    missing = sources(p, src_dir)
    p.save(out_path)
    if missing:
        sys.exit("some src files have no script in the place")


if __name__ == "__main__":
    main()
