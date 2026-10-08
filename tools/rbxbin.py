"""Minimal lossless reader/writer for Roblox binary place files (.rbxl).

Chunks are kept as raw bytes; only the chunks we touch are decoded and re-encoded.
"""
import struct

import lz4.block
import zstandard

MAGIC = b"<roblox!\x89\xff\r\n\x1a\n"


class Chunk:
    def __init__(self, name, data, compressed):
        self.name = name
        self.data = data  # uncompressed payload
        self.compressed = compressed  # how it was stored ("lz4" / "zstd" / None)


def read_place(path):
    raw = open(path, "rb").read()
    assert raw[:14] == MAGIC, "not a binary place"
    version, nclass, ninst = struct.unpack_from("<Hii", raw, 14)
    pos = 32
    chunks = []
    while pos < len(raw):
        name = raw[pos : pos + 4]
        clen, ulen, _res = struct.unpack_from("<III", raw, pos + 4)
        pos += 16
        if clen == 0:
            data = raw[pos : pos + ulen]
            pos += ulen
            comp = None
        else:
            blob = raw[pos : pos + clen]
            pos += clen
            if blob[:4] == b"\x28\xb5\x2f\xfd":
                data = zstandard.ZstdDecompressor().decompress(blob, max_output_size=ulen)
                comp = "zstd"
            else:
                data = lz4.block.decompress(blob, uncompressed_size=ulen)
                comp = "lz4"
        chunks.append(Chunk(name, data, comp))
        if name == b"END\0":
            break
    return {"version": version, "nclass": nclass, "ninst": ninst, "chunks": chunks}


def write_place(place, path):
    out = bytearray()
    out += MAGIC
    out += struct.pack("<Hii", place["version"], place["nclass"], place["ninst"])
    out += b"\0" * 8
    for c in place["chunks"]:
        data = bytes(c.data)
        if c.compressed == "lz4" and c.name != b"END\0":
            comp = lz4.block.compress(data, store_size=False)
            out += c.name + struct.pack("<III", len(comp), len(data), 0) + comp
        elif c.compressed == "zstd" and c.name != b"END\0":
            comp = zstandard.ZstdCompressor().compress(data)
            out += c.name + struct.pack("<III", len(comp), len(data), 0) + comp
        else:
            out += c.name + struct.pack("<III", 0, len(data), 0) + data
    open(path, "wb").write(bytes(out))


# ---------------------------------------------------------------- primitives
class Reader:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.d, self.p)[0]
        self.p += 4
        return v

    def string(self):
        n = self.u32()
        v = bytes(self.d[self.p : self.p + n])
        self.p += n
        return v

    def raw(self, n):
        v = bytes(self.d[self.p : self.p + n])
        self.p += n
        return v

    def rest(self):
        return bytes(self.d[self.p :])


def deinterleave(buf, count, width):
    out = []
    for i in range(count):
        out.append(bytes(buf[b * count + i] for b in range(width)))
    return out


def interleave(items, width):
    count = len(items)
    out = bytearray(count * width)
    for i, it in enumerate(items):
        for b in range(width):
            out[b * count + i] = it[b]
    return bytes(out)


def i32_array(r, count):
    raw = r.raw(count * 4)
    vals = []
    for b in deinterleave(raw, count, 4):
        u = int.from_bytes(b, "big")
        vals.append((u >> 1) ^ -(u & 1))
    return vals


def i32_bytes(vals):
    items = []
    for v in vals:
        u = ((v << 1) ^ (v >> 31)) & 0xFFFFFFFF
        items.append(u.to_bytes(4, "big"))
    return interleave(items, 4)


def ref_array(r, count):
    vals = i32_array(r, count)
    acc = 0
    out = []
    for v in vals:
        acc += v
        out.append(acc)
    return out


def ref_bytes(refs):
    prev = 0
    deltas = []
    for v in refs:
        deltas.append(v - prev)
        prev = v
    return i32_bytes(deltas)


def f32_array(r, count):
    raw = r.raw(count * 4)
    out = []
    for b in deinterleave(raw, count, 4):
        u = int.from_bytes(b, "big")
        u = (u >> 1) | ((u & 1) << 31)
        out.append(struct.unpack("<f", struct.pack("<I", u))[0])
    return out


def f32_bytes(vals):
    items = []
    for v in vals:
        u = struct.unpack("<I", struct.pack("<f", v))[0]
        u = ((u << 1) | (u >> 31)) & 0xFFFFFFFF
        items.append(u.to_bytes(4, "big"))
    return interleave(items, 4)


def u32_array(r, count):
    raw = r.raw(count * 4)
    return [int.from_bytes(b, "big") for b in deinterleave(raw, count, 4)]


# ---------------------------------------------------------------- structure
def index(place):
    """classes: id -> {name, refs}; props: list of (chunk, class_id, prop_name, type)."""
    classes = {}
    props = []
    parents = {}
    for c in place["chunks"]:
        if c.name == b"INST":
            r = Reader(c.data)
            cid = r.u32()
            name = r.string().decode()
            svc = r.u8()
            n = r.u32()
            refs = ref_array(r, n)
            classes[cid] = {"name": name, "refs": refs, "service": svc, "chunk": c}
        elif c.name == b"PROP":
            r = Reader(c.data)
            cid = r.u32()
            pname = r.string().decode()
            t = r.u8()
            props.append({"chunk": c, "cid": cid, "name": pname, "type": t, "start": r.p})
        elif c.name == b"PRNT":
            r = Reader(c.data)
            r.u8()
            n = r.u32()
            kids = ref_array(r, n)
            pars = ref_array(r, n)
            for k, p in zip(kids, pars):
                parents[k] = p
    return classes, props, parents


def read_strings(prop, count):
    r = Reader(prop["chunk"].data, prop["start"])
    return [r.string() for _ in range(count)]


def write_strings(prop, values):
    c = prop["chunk"]
    head = bytes(c.data[: prop["start"]])
    body = b"".join(struct.pack("<I", len(v)) + v for v in values)
    c.data = head + body


# ---------------------------------------------------------------- decoding (read-only model)
ROT = None


def _rot_table():
    # the 24 axis-aligned rotations by id (id -> 3x3 row-major), per the binary spec
    import itertools

    vecs = {0: (1, 0, 0), 1: (0, 1, 0), 2: (0, 0, 1), 3: (-1, 0, 0), 4: (0, -1, 0), 5: (0, 0, -1)}
    table = {}
    for r, u in itertools.product(range(6), range(6)):
        rv, uv = vecs[r], vecs[u]
        if sum(a * b for a, b in zip(rv, uv)) != 0:
            continue
        bv = (rv[1] * uv[2] - rv[2] * uv[1], rv[2] * uv[0] - rv[0] * uv[2], rv[0] * uv[1] - rv[1] * uv[0])
        table[(r * 6 + u) + 1] = (rv, uv, bv)
    return table


def decode(prop, count):
    t = prop["type"]
    r = Reader(prop["chunk"].data, prop["start"])
    if t == 0x01:
        return [r.string() for _ in range(count)]
    if t == 0x02:
        return [b != 0 for b in r.raw(count)]
    if t == 0x03:
        return i32_array(r, count)
    if t == 0x04:
        return f32_array(r, count)
    if t == 0x05:
        return [struct.unpack("<d", r.raw(8))[0] for _ in range(count)]
    if t == 0x0C:
        a, b, c = f32_array(r, count), f32_array(r, count), f32_array(r, count)
        return list(zip(a, b, c))
    if t == 0x0D:
        a, b = f32_array(r, count), f32_array(r, count)
        return list(zip(a, b))
    if t == 0x0E:
        a, b, c = f32_array(r, count), f32_array(r, count), f32_array(r, count)
        return list(zip(a, b, c))
    if t == 0x10:
        global ROT
        ROT = ROT or _rot_table()
        rots = []
        for _ in range(count):
            rid = r.u8()
            if rid == 0:
                rots.append(struct.unpack("<9f", r.raw(36)))
            else:
                rv, uv, bv = ROT[rid]
                # rows of the matrix: right, up, back are columns
                rots.append((rv[0], uv[0], bv[0], rv[1], uv[1], bv[1], rv[2], uv[2], bv[2]))
        x, y, z = f32_array(r, count), f32_array(r, count), f32_array(r, count)
        return [(p, rot) for p, rot in zip(zip(x, y, z), rots)]
    if t == 0x12:
        return u32_array(r, count)
    if t == 0x13:
        return ref_array(r, count)
    if t == 0x15:
        out = []
        for _ in range(count):
            n = r.u32()
            out.append([struct.unpack("<3f", r.raw(12)) for _ in range(n)])
        return out
    if t == 0x16:
        out = []
        for _ in range(count):
            n = r.u32()
            out.append([struct.unpack("<5f", r.raw(20)) for _ in range(n)])
        return out
    if t == 0x17:
        return [struct.unpack("<2f", r.raw(8)) for _ in range(count)]
    if t == 0x1A:
        raw = r.raw(count * 3)
        return [(raw[i], raw[count + i], raw[2 * count + i]) for i in range(count)]
    if t == 0x22:
        types = i32_array(r, count)
        n = r.u32()
        uris = [r.string() for _ in range(n)]
        out = []
        k = 0
        for ty in types:
            if ty == 1:
                out.append(uris[k].decode())
                k += 1
            else:
                out.append("")
        return out
    return None


class Inst:
    __slots__ = ("ref", "cls", "props", "parent", "children")

    def __init__(self, ref, cls):
        self.ref = ref
        self.cls = cls
        self.props = {}
        self.parent = None
        self.children = []

    @property
    def name(self):
        n = self.props.get("Name")
        return n.decode("utf-8", "replace") if isinstance(n, bytes) else str(n)

    def path(self):
        parts = []
        node = self
        while node is not None:
            parts.append(node.name)
            node = node.parent
        return "/".join(reversed(parts))

    def find(self, *names):
        node = self
        for n in names:
            node = next((c for c in node.children if c.name == n), None)
            if node is None:
                return None
        return node

    def descendants(self):
        for c in self.children:
            yield c
            yield from c.descendants()


def model(place, want_props=None):
    classes, props, parents = index(place)
    insts = {}
    for cid, c in classes.items():
        for ref in c["refs"]:
            insts[ref] = Inst(ref, c["name"])
    for p in props:
        if want_props is not None and p["name"] not in want_props:
            continue
        c = classes[p["cid"]]
        vals = decode(p, len(c["refs"]))
        if vals is None:
            continue
        for ref, v in zip(c["refs"], vals):
            insts[ref].props[p["name"]] = v
    roots = []
    for ref, inst in insts.items():
        pr = parents.get(ref, -1)
        if pr in insts:
            inst.parent = insts[pr]
            insts[pr].children.append(inst)
        else:
            roots.append(inst)
    # keep the file's child order (PRNT order)
    return insts, roots


# ---------------------------------------------------------------- per-instance items (for cloning)
FIXED = {0x03: 4, 0x04: 4, 0x12: 4, 0x1B: 8, 0x1C: 4, 0x1F: 16, 0x21: 8, 0x0B: 4}
VEC = {0x0C: 3, 0x0E: 3, 0x0D: 2}


def split(ptype, data, count):
    """Per-instance opaque items of a PROP payload (after its header); join() rebuilds the payload."""
    r = Reader(data)
    if ptype == 0x01:
        items = [r.string() for _ in range(count)]
    elif ptype == 0x02:
        items = [bytes([b]) for b in r.raw(count)]
    elif ptype in FIXED:
        w = FIXED[ptype]
        items = deinterleave(r.raw(count * w), count, w)
    elif ptype in VEC:
        n = VEC[ptype]
        arrays = [deinterleave(r.raw(count * 4), count, 4) for _ in range(n)]
        items = [tuple(a[i] for a in arrays) for i in range(count)]
    elif ptype == 0x10:
        rots = []
        for _ in range(count):
            rid = r.u8()
            rots.append(bytes([rid]) + (r.raw(36) if rid == 0 else b""))
        arrays = [deinterleave(r.raw(count * 4), count, 4) for _ in range(3)]
        items = [(rots[i], arrays[0][i], arrays[1][i], arrays[2][i]) for i in range(count)]
    elif ptype == 0x19:
        items = []
        for _ in range(count):
            flag = r.u8()
            if flag == 0:
                items.append(bytes([flag]))
            elif flag == 1:
                items.append(bytes([flag]) + r.raw(20))
            elif flag == 3:
                items.append(bytes([flag]) + r.raw(24))
            else:
                raise ValueError("PhysicalProperties flag %d" % flag)
    elif ptype == 0x1A:
        raw = r.raw(count * 3)
        items = [bytes([raw[i], raw[count + i], raw[2 * count + i]]) for i in range(count)]
    elif ptype == 0x22:
        types = deinterleave(r.raw(count * 4), count, 4)
        n = r.u32()
        uris = [r.string() for _ in range(n)]
        tail = r.raw(8)
        if tail != b"\0" * 8:
            raise ValueError("Content with object references")
        items = []
        k = 0
        for t in types:
            v = int.from_bytes(t, "big")
            if v == 2:  # zigzag(1) = Uri
                items.append((t, uris[k]))
                k += 1
            else:
                items.append((t, None))
    else:
        raise ValueError("no splitter for type 0x%02x" % ptype)
    if r.p != len(data):
        raise ValueError("type 0x%02x: %d trailing bytes" % (ptype, len(data) - r.p))
    return items


def join(ptype, items):
    count = len(items)
    if ptype == 0x01:
        return b"".join(struct.pack("<I", len(v)) + v for v in items)
    if ptype == 0x02:
        return b"".join(items)
    if ptype in FIXED:
        return interleave(items, FIXED[ptype])
    if ptype in VEC:
        n = VEC[ptype]
        return b"".join(interleave([it[k] for it in items], 4) for k in range(n))
    if ptype == 0x10:
        return b"".join(it[0] for it in items) + b"".join(interleave([it[k] for it in items], 4) for k in (1, 2, 3))
    if ptype == 0x19:
        return b"".join(items)
    if ptype == 0x1A:
        return bytes(it[0] for it in items) + bytes(it[1] for it in items) + bytes(it[2] for it in items)
    if ptype == 0x22:
        uris = [u for _, u in items if u is not None]
        return interleave([t for t, _ in items], 4) + struct.pack("<I", len(uris)) + b"".join(struct.pack("<I", len(u)) + u for u in uris) + b"\0" * 8
    raise ValueError("no joiner for type 0x%02x" % ptype)


def f32_item(v):
    u = struct.unpack("<I", struct.pack("<f", v))[0]
    return (((u << 1) | (u >> 31)) & 0xFFFFFFFF).to_bytes(4, "big")


def cframe_item(pos, rot9=None):
    """A CFrame item: position, rotation as 9 floats (row-major R00 R01 R02 R10 ...) or identity."""
    if rot9 is None:
        rot = bytes([0x02])  # identity rotation id
    else:
        rot = bytes([0]) + struct.pack("<9f", *rot9)
    return (rot, f32_item(pos[0]), f32_item(pos[1]), f32_item(pos[2]))


def clone_instances(place, plan):
    """plan: list of (source_ref, parent_ref, overrides{prop: item}). Appends copies of the sources (no
    children) as new instances of the same class, parented as given. Returns the new referents."""
    classes, props, parents = index(place)
    by_ref = {}
    for cid, c in classes.items():
        for i, ref in enumerate(c["refs"]):
            by_ref[ref] = (cid, i)
    next_ref = max(by_ref) + 1
    new_refs = []
    adds = {}  # cid -> list of (src index, new ref, overrides)
    for src, parent, over in plan:
        cid, i = by_ref[src]
        adds.setdefault(cid, []).append((i, next_ref, over, parent))
        new_refs.append((next_ref, parent))
        next_ref += 1
    for cid, lst in adds.items():
        c = classes[cid]
        count = len(c["refs"])
        # the INST chunk: the class's referents (and a service's flags)
        ic = c["chunk"]
        r = Reader(ic.data)
        r.u32()
        name = r.string()
        svc = r.u8()
        assert svc == 0, "cloning a service"
        refs = c["refs"] + [nr for _, nr, _, _ in lst]
        ic.data = struct.pack("<I", cid) + struct.pack("<I", len(name)) + name + bytes([svc]) + struct.pack("<I", len(refs)) + ref_bytes(refs)
        for p in props:
            if p["cid"] != cid:
                continue
            ch = p["chunk"]
            head = bytes(ch.data[: p["start"]])
            items = split(p["type"], bytes(ch.data[p["start"] :]), count)
            for i, nr, over, _ in lst:
                it = over.get(p["name"], items[i])
                items.append(it)
            ch.data = head + join(p["type"], items)
    # parents: appended after every existing pair
    for c in place["chunks"]:
        if c.name == b"PRNT":
            r = Reader(c.data)
            ver = r.u8()
            n = r.u32()
            kids = ref_array(r, n)
            pars = ref_array(r, n)
            kids += [nr for nr, _ in new_refs]
            pars += [pr for _, pr in new_refs]
            c.data = bytes([ver]) + struct.pack("<I", len(kids)) + ref_bytes(kids) + ref_bytes(pars)
    place["ninst"] += len(new_refs)
    return [nr for nr, _ in new_refs]
