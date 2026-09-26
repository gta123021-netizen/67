#!/usr/bin/env python3
"""Write a Rojo-style sourcemap.json for a place so luau-lsp can resolve requires.

    python3 tools/sourcemap.py <place.rbxl> <src dir> <out sourcemap.json>

Every instance down to the scripts is listed (name + class); scripts point at their file in src/.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402
from extract_rbxl import EXT, file_name  # noqa: E402

SKIP = {"Workspace", "Lighting", "ServerStorage"}


def main():
    place_path, src_dir, out = sys.argv[1:4]
    p = rbxl.Place(place_path)
    has_script = set()
    for cid, info in p.classes.items():
        if info["name"] in EXT:
            for r in info["refs"]:
                cur = r
                while cur is not None and cur != -1:
                    has_script.add(cur)
                    cur = p.parent.get(cur)

    def node(ref):
        cls = p.class_name(ref)
        n = {"name": p.names.get(ref, cls), "className": cls}
        if cls in EXT:
            n["filePaths"] = [os.path.join(src_dir, file_name(p.path(ref), cls))]
        kids = [k for k in p.children.get(ref, []) if k in has_script or p.class_name(k) in ("RemoteEvent", "RemoteFunction", "BindableEvent", "Folder")]
        if kids:
            n["children"] = [node(k) for k in kids]
        return n

    roots = [r for r in p.ref_class if p.parent.get(r, -1) == -1 and r in has_script]
    tree = {"name": "Game", "className": "DataModel", "children": [node(r) for r in roots]}
    json.dump(tree, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
