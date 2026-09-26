#!/usr/bin/env python3
"""Extract every script in a binary place (.rbxl) into a folder of .lua files.

    python3 tools/extract_rbxl.py <place.rbxl> <out dir>

File names are the script's path in the game tree joined with "__" (spaces become "_") plus
.server.lua / .client.lua / .lua - the same scheme tools/build_rbxl.py writes back from.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402

EXT = {"Script": ".server.lua", "LocalScript": ".client.lua", "ModuleScript": ".lua"}


def file_name(path, cls):
    return "__".join(path).replace("/", "_").replace(" ", "_") + EXT[cls]


def scripts(place):
    for cid, info in place.classes.items():
        if info["name"] not in EXT:
            continue
        sources = place.get_strings(cid, "Source")
        for i, ref in enumerate(info["refs"]):
            yield cid, i, ref, info["name"], place.path(ref), sources[i]


def main():
    place_path, out_dir = sys.argv[1:3]
    place = rbxl.Place(place_path)
    os.makedirs(out_dir, exist_ok=True)
    seen = {}
    for _cid, _i, _ref, cls, path, src in scripts(place):
        name = file_name(path, cls)
        seen[name] = seen.get(name, 0) + 1
        if seen[name] > 1:
            print("duplicate path, skipped:", "/".join(path))
            continue
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(src)
    print(sum(seen.values()), "scripts")


if __name__ == "__main__":
    main()
