#!/usr/bin/env python3
"""Write edited scripts (and copies of library meshes) into a binary Roblox place (.rbxl).

    python3 build_rbxl.py <in.rbxl> <src dir> <out.rbxl> [--copy "<from path>=<to folder path>/<name>"]...

Every script whose path is unique and whose file in <src dir> differs gets that file's source. Each
--copy adds a copy of an instance (no children) under another folder, with a new name. Everything
else in the place is kept byte for byte (chunks are re-compressed, their contents are not touched).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxbin  # noqa: E402

EXT = {"Script": ".server.lua", "LocalScript": ".client.lua", "ModuleScript": ".lua"}


def file_name(path, cls):
    return path.replace("/", "__").replace(" ", "_") + EXT[cls]


def main():
    args = sys.argv[1:]
    copies = []
    while "--copy" in args:
        i = args.index("--copy")
        copies.append(args[i + 1])
        del args[i : i + 2]
    src_path, src_dir, out_path = args
    place = rbxbin.read_place(src_path)
    insts, _ = rbxbin.model(place, want_props={"Name"})
    by_path = {}
    for inst in insts.values():
        by_path.setdefault(inst.path(), []).append(inst)

    # copies of instances (MeshParts from the VFX library into the ability's assets)
    plan = []
    for spec in copies:
        frm, to = spec.split("=")
        folder, name = to.rsplit("/", 1)
        srcs = [i for i in by_path.get(frm, [])]
        dsts = by_path.get(folder, [])
        assert srcs, "no instance at " + frm
        assert len(dsts) == 1, "folder %s: %d matches" % (folder, len(dsts))
        assert not any(c.name == name for c in dsts[0].children), "%s/%s exists" % (folder, name)
        src = srcs[0]
        uid = bytearray(os.urandom(16))
        plan.append((src.ref, dsts[0].ref, {"Name": name.encode(), "UniqueId": bytes(uid)}))
        print("copy", frm, "->", to, "(%s)" % src.cls)
    if plan:
        rbxbin.clone_instances(place, plan)

    # script sources
    classes, props, _ = rbxbin.index(place)
    insts, _ = rbxbin.model(place, want_props={"Name"})
    counts = {}
    for inst in insts.values():
        if inst.cls in EXT:
            counts[inst.path()] = counts.get(inst.path(), 0) + 1
    updated = 0
    for p in props:
        cls = classes[p["cid"]]["name"]
        if p["name"] != "Source" or cls not in EXT:
            continue
        refs = classes[p["cid"]]["refs"]
        data = bytes(p["chunk"].data[p["start"] :])
        items = rbxbin.split(p["type"], data, len(refs))
        changed = False
        for k, ref in enumerate(refs):
            inst = insts[ref]
            path = inst.path()
            fn = os.path.join(src_dir, file_name(path, cls))
            if counts[path] != 1 or not os.path.exists(fn):
                continue
            new = open(fn, "rb").read()
            if new != items[k]:
                items[k] = new
                changed = True
                updated += 1
                print("updated", path)
        if changed:
            head = bytes(p["chunk"].data[: p["start"]])
            p["chunk"].data = head + rbxbin.join(p["type"], items)
    rbxbin.write_place(place, out_path)
    print("%d scripts updated, %d instances added -> %s" % (updated, len(plan), out_path))


if __name__ == "__main__":
    main()
