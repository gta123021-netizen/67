#!/usr/bin/env python3
"""Proves tools/rbxl.py's instance deletion on a real place.

    python3 tools/rbxl_delete_check.py <place.rbxl> <path to delete, e.g. ServerStorage/VFXLibrary>

1. every PROP chunk of the place splits into per-value items and joins back byte for byte
2. the subtree is deleted, the place saved and read back; then every instance that was kept has
   the same class, name, parent path and every property value it had (Referents compared by the
   instance they point at, SharedStrings by their content); nothing that was deleted is left
"""
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rbxl  # noqa: E402


def columns(p):
    """{(class name, prop name): (type, [values in the class's ref order])}"""
    out = {}
    for (cid, pname), ch in p.props.items():
        d = ch.data
        nlen = struct.unpack_from("<I", d, 4)[0]
        head = 8 + nlen + 1
        t = d[head - 1]
        n = len(p.classes[cid]["refs"])
        items, end = rbxl.split_values(t, d, head, n)
        assert end == len(d), "%s.%s: column ends at %d of %d" % (p.classes[cid]["name"], pname, end, len(d))
        assert rbxl.join_values(t, items) == bytes(d[head:]), "%s.%s: split/join not exact" % (p.classes[cid]["name"], pname)
        out[(cid, pname)] = (t, items)
    return out


def shared(p):
    ch = next((c for c in p.chunks if c.name == b"SSTR"), None)
    return rbxl._sstr_parse(ch.data)[1] if ch else []


def snapshot(p, cols, ids):
    """per instance (by a stable id): class, parent id, and every property value"""
    ss = shared(p)
    snap = {}
    for cid, info in p.classes.items():
        for i, r in enumerate(info["refs"]):
            snap[ids[r]] = {"Class": info["name"], "Parent": ids.get(p.parent.get(r, -1))}
    for (cid, pname), (t, items) in cols.items():
        info = p.classes[cid]
        for i, r in enumerate(info["refs"]):
            v = items[i]
            if t == 0x13:
                v = ids.get(v)
            elif t == 0x1C:
                v = ss[int.from_bytes(v, "big")]
            snap[ids[r]][pname] = (t, v)
    return snap


def main():
    path, target = sys.argv[1], sys.argv[2]
    p = rbxl.Place(path)
    cols = columns(p)
    print("1. %d property columns split and join back byte for byte" % len(cols))
    # a stable identity for each instance: its referent in the original place
    before = snapshot(p, cols, {r: r for r in p.ref_class})
    root = p.find(target)
    assert root is not None, "no " + target
    removed = p.delete_subtrees([root])
    fd, tmp = tempfile.mkstemp(suffix=".rbxl")
    os.close(fd)
    p.save(tmp)
    q = rbxl.Place(tmp)
    qcols = columns(q)
    # map the new referents back to the original ones through the kept order (renumbering keeps it)
    dead = _dead(before, root)
    old_kept = sorted(r for r in before if r not in dead)
    assert len(old_kept) == len(q.ref_class), (len(old_kept), len(q.ref_class))
    back = {new: old for new, old in zip(sorted(q.ref_class), old_kept)}
    after = snapshot(q, qcols, back)
    bad = 0
    for old in old_kept:
        a, b = before[old], after[old]
        if a != b:
            keys = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
            if bad < 10:
                print("  MISMATCH", old, a["Class"], keys[:5])
            bad += 1
    print("2. deleted %s: %d instances removed, %d kept, %d changed" % (target, removed, len(old_kept), bad))
    print("   %d -> %d bytes, %d -> %d shared strings" % (os.path.getsize(path), os.path.getsize(tmp), len(shared(rbxl.Place(path))), len(shared(q))))
    left = q.find(target)
    os.remove(tmp)
    if bad or left is not None or q.inst_count != len(q.ref_class) or q.class_count != len(q.classes):
        sys.exit("FAIL")
    print("OK")


def _dead(before, root):
    kids = {}
    for r, v in before.items():
        kids.setdefault(v["Parent"], []).append(r)
    dead, stack = set(), [root]
    while stack:
        r = stack.pop()
        if r not in dead:
            dead.add(r)
            stack.extend(kids.get(r, []))
    return dead


if __name__ == "__main__":
    main()
