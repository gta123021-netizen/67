#!/usr/bin/env python3
"""Inspect VFX packs inside a place: a subtree with classes, emitter settings and attributes.

    python3 tools/vfxlib.py <place.rbxl> "Workspace/Anime/Punch-01" [more paths...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402

EMITTER_PROPS = ["Texture", "Rate", "Lifetime", "Speed", "Size", "Transparency", "LightEmission", "Drag", "Acceleration",
                 "SpreadAngle", "EmissionDirection", "Orientation", "ZOffset", "FlipbookLayout", "Rotation", "RotSpeed",
                 "Enabled", "LockedToPart", "Squash", "Color", "Brightness", "TimeScale", "VelocityInheritance"]


class Lib:
    def __init__(self, path):
        self.place = rbxl.Place(path)
        self.cache = {}
        self.index = {}
        for cid, info in self.place.classes.items():
            for i, r in enumerate(info["refs"]):
                self.index[r] = (cid, i)

    def prop(self, ref, pname):
        cid, i = self.index[ref]
        key = (cid, pname)
        if key not in self.cache:
            self.cache[key] = rbxl.decode_prop(self.place, cid, pname)
        vals = self.cache[key]
        return None if vals is None else vals[i]

    def attrs(self, ref):
        cid, i = self.index[ref]
        vals = self.place.get_strings(cid, "AttributesSerialize")
        return rbxl.decode_attributes(vals[i]) if vals else {}

    def find(self, path):
        parts = path.split("/")
        cands = [r for r in self.place.ref_class if self.place.parent.get(r, -1) in (-1, None) and self.place.names.get(r) == parts[0]]
        for name in parts[1:]:
            nxt = []
            for c in cands:
                nxt += [k for k in self.place.children.get(c, []) if self.place.names.get(k) == name]
            cands = nxt
        return cands

    def dump(self, ref, depth=0, maxdepth=6, emit=True):
        p = self.place
        cls = p.class_name(ref)
        line = "  " * depth + "%s [%s]" % (p.names.get(ref), cls)
        a = self.attrs(ref)
        if a:
            line += " attrs=" + ", ".join("%s=%s" % (k, _short(v)) for k, v in a.items())
        if cls in ("Part", "MeshPart"):
            line += " size=%s" % (_short(self.prop(ref, "size") or self.prop(ref, "Size")),)
            if cls == "MeshPart":
                line += " mesh=%s tex=%s" % (self.prop(ref, "MeshContent") or self.prop(ref, "MeshId"), self.prop(ref, "TextureContent") or self.prop(ref, "TextureID"))
        if cls in ("Decal", "Texture"):
            line += " tex=%s" % (self.prop(ref, "TextureContent") or self.prop(ref, "Texture"),)
        print(line)
        if cls == "ParticleEmitter" and emit:
            for k in EMITTER_PROPS:
                v = self.prop(ref, k)
                if v is not None:
                    print("  " * depth + "    %s = %s" % (k, _short(v)))
        if cls == "Beam" and emit:
            for k in ["Texture", "Width0", "Width1", "TextureSpeed", "TextureLength", "LightEmission", "Transparency", "Segments", "FaceCamera", "CurveSize0", "CurveSize1", "Color"]:
                v = self.prop(ref, k)
                if v is not None:
                    print("  " * depth + "    %s = %s" % (k, _short(v)))
        if depth < maxdepth:
            for k in self.place.children.get(ref, []):
                self.dump(k, depth + 1, maxdepth, emit)


def _short(v):
    if isinstance(v, float):
        return "%.3g" % v
    if isinstance(v, (list, tuple)):
        s = "(" + ", ".join(_short(x) for x in v) + ")"
        return s if len(s) < 140 else s[:137] + "...)"
    return str(v)


if __name__ == "__main__":
    lib = Lib(sys.argv[1])
    for path in sys.argv[2:]:
        for r in lib.find(path):
            lib.dump(r)
            print()
