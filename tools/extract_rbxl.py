#!/usr/bin/env python3
"""Extract every script of a binary Roblox place (.rbxl) as plain Luau.

    python3 tools/extract_rbxl.py <in.rbxl> <out dir>

File name = the script's path in the game tree joined with "__" (spaces become "_") plus
.server.lua / .client.lua / .lua - the names tools/build_rbxl.py writes back. Scripts whose path is
not unique (copies inside the VFX packs) are left out: build_rbxl.py never writes those either.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxbin  # noqa: E402

EXT = {"Script": ".server.lua", "LocalScript": ".client.lua", "ModuleScript": ".lua"}


def main():
    src, out = sys.argv[1:3]
    place = rbxbin.read_place(src)
    insts, _ = rbxbin.model(place, want_props={"Name", "Source"})
    scripts = [i for i in insts.values() if i.cls in EXT]
    counts = {}
    for i in scripts:
        counts[i.path()] = counts.get(i.path(), 0) + 1
    os.makedirs(out, exist_ok=True)
    n = skipped = 0
    for i in scripts:
        path = i.path()
        if counts[path] != 1:
            skipped += 1
            continue
        fn = os.path.join(out, path.replace("/", "__").replace(" ", "_") + EXT[i.cls])
        with open(fn, "wb") as f:
            f.write(i.props.get("Source", b""))
        n += 1
    print("%d scripts -> %s (%d copies with the same path left out)" % (n, out, skipped))


if __name__ == "__main__":
    main()
