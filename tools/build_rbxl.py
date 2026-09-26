#!/usr/bin/env python3
"""Write the scripts in src/ back into a binary place (.rbxl).

    python3 tools/build_rbxl.py <in.rbxl> <src dir> <out.rbxl>

Every script whose path in the game tree is unique and whose file in src/ differs from the source
in the place gets the file's source. Only the PROP chunks holding a changed Source are re-encoded;
every other byte of the place is copied through unchanged. File names are the script's path joined
with "__" (spaces become "_") plus .server.lua / .client.lua / .lua (tools/extract_rbxl.py).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402
from extract_rbxl import EXT, file_name  # noqa: E402


def main():
    in_path, src_dir, out_path = sys.argv[1:4]
    place = rbxl.Place(in_path)
    counts = {}
    for cid, info in place.classes.items():
        if info["name"] in EXT:
            for ref in info["refs"]:
                name = file_name(place.path(ref), info["name"])
                counts[name] = counts.get(name, 0) + 1
    changed = []
    used = set()
    for cid, info in place.classes.items():
        if info["name"] not in EXT:
            continue
        sources = place.get_strings(cid, "Source")
        dirty = False
        for i, ref in enumerate(info["refs"]):
            name = file_name(place.path(ref), info["name"])
            if counts[name] != 1:
                continue
            fp = os.path.join(src_dir, name)
            if not os.path.exists(fp):
                continue
            used.add(name)
            new = open(fp, "rb").read()
            if new != sources[i]:
                sources[i] = new
                dirty = True
                changed.append(name)
        if dirty:
            place.set_strings(cid, "Source", sources)
    missing = sorted(n for n in os.listdir(src_dir) if n.endswith(".lua") and n not in used and counts.get(n, 0) <= 1)
    for n in missing:
        print("not in the place (skipped):", n)
    place.save(out_path)
    print("%d scripts changed" % len(changed))
    for n in sorted(changed):
        print("  " + n)


if __name__ == "__main__":
    main()
