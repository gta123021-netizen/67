#!/usr/bin/env python3
"""Minimal reader/writer for Roblox binary place files (.rbxl).

Reads every chunk, decodes the instance tree (INST/PRNT) and String properties (such as
Script.Source and Instance.Name), and writes the place back with only the PROP chunks that
changed re-encoded. Every other chunk is copied through byte for byte.
"""
import struct

import lz4.block

try:
    import zstandard
except ImportError:  # only needed for zstd-compressed chunks
    zstandard = None

MAGIC = b"<roblox!\x89\xff\r\n\x1a\n"


def _untransform_i32(u):
    return (u >> 1) ^ -(u & 1)


def _transform_i32(v):
    return ((v << 1) ^ (v >> 31)) & 0xFFFFFFFF


def read_interleaved_u32(buf, pos, count):
    out = []
    for i in range(count):
        out.append(
            (buf[pos + i] << 24)
            | (buf[pos + count + i] << 16)
            | (buf[pos + 2 * count + i] << 8)
            | buf[pos + 3 * count + i]
        )
    return out, pos + 4 * count


def write_interleaved_u32(values):
    n = len(values)
    out = bytearray(4 * n)
    for i, v in enumerate(values):
        out[i] = (v >> 24) & 0xFF
        out[n + i] = (v >> 16) & 0xFF
        out[2 * n + i] = (v >> 8) & 0xFF
        out[3 * n + i] = v & 0xFF
    return bytes(out)


def read_referents(buf, pos, count):
    raw, pos = read_interleaved_u32(buf, pos, count)
    refs = []
    acc = 0
    for u in raw:
        acc += _untransform_i32(u)
        refs.append(acc)
    return refs, pos


def write_referents(refs):
    raw = []
    prev = 0
    for r in refs:
        raw.append(_transform_i32(r - prev))
        prev = r
    return write_interleaved_u32(raw)


class Chunk:
    def __init__(self, name, raw, data, compressed, reserved):
        self.name = name
        self.raw = raw  # the exact on-disk bytes (header + payload)
        self.data = data  # decompressed payload
        self.compressed = compressed
        self.reserved = reserved
        self.dirty = False

    def encode(self):
        if not self.dirty:
            return self.raw
        if self.compressed:
            comp = lz4.block.compress(self.data, store_size=False)
            header = self.name + struct.pack("<III", len(comp), len(self.data), 0)
            return header + comp
        header = self.name + struct.pack("<III", 0, len(self.data), 0)
        return header + self.data


class Place:
    def __init__(self, path):
        blob = open(path, "rb").read()
        if not blob.startswith(MAGIC):
            raise SystemExit("not a binary Roblox place: %s" % path)
        self.header = blob[:32]
        self.version, self.class_count, self.inst_count = struct.unpack_from("<HII", blob, 14)
        self.chunks = []
        pos = 32
        while pos < len(blob):
            name = blob[pos : pos + 4]
            clen, ulen, reserved = struct.unpack_from("<III", blob, pos + 4)
            start = pos
            pos += 16
            size = clen if clen else ulen
            payload = blob[pos : pos + size]
            pos += size
            if clen:
                if payload[:4] == b"\x28\xb5\x2f\xfd":
                    data = zstandard.ZstdDecompressor().decompress(payload, max_output_size=ulen)
                else:
                    data = lz4.block.decompress(payload, uncompressed_size=ulen)
            else:
                data = payload
            self.chunks.append(Chunk(name, blob[start:pos], data, bool(clen), reserved))
            if name == b"END\0":
                break
        self._parse()

    # ------------------------------------------------------------------ parsing
    def _parse(self):
        self.classes = {}  # class id -> dict(name, refs, service)
        self.ref_class = {}  # referent -> class id
        self.props = {}  # (class id, prop name) -> chunk
        self.parent = {}
        for ch in self.chunks:
            d = ch.data
            if ch.name == b"INST":
                cid, nlen = struct.unpack_from("<II", d, 0)
                cname = d[8 : 8 + nlen].decode()
                p = 8 + nlen
                fmt = d[p]
                count = struct.unpack_from("<I", d, p + 1)[0]
                refs, p2 = read_referents(d, p + 5, count)
                self.classes[cid] = {"name": cname, "refs": refs, "service": fmt, "chunk": ch}
                for r in refs:
                    self.ref_class[r] = cid
            elif ch.name == b"PROP":
                cid, nlen = struct.unpack_from("<II", d, 0)
                pname = d[8 : 8 + nlen].decode()
                self.props[(cid, pname)] = ch
            elif ch.name == b"PRNT":
                count = struct.unpack_from("<I", d, 1)[0]
                kids, p = read_referents(d, 5, count)
                pars, p = read_referents(d, p, count)
                for k, pa in zip(kids, pars):
                    self.parent[k] = pa
        self.children = {}
        for k, pa in self.parent.items():
            self.children.setdefault(pa, []).append(k)
        self.names = {}
        for cid, info in self.classes.items():
            vals = self.get_strings(cid, "Name")
            if vals is not None:
                for r, v in zip(info["refs"], vals):
                    self.names[r] = v.decode("utf-8", "replace")

    def prop_type(self, cid, pname):
        ch = self.props.get((cid, pname))
        if ch is None:
            return None
        nlen = struct.unpack_from("<I", ch.data, 4)[0]
        return ch.data[8 + nlen]

    def get_strings(self, cid, pname):
        ch = self.props.get((cid, pname))
        if ch is None:
            return None
        d = ch.data
        nlen = struct.unpack_from("<I", d, 4)[0]
        p = 8 + nlen
        if d[p] != 0x01:
            return None
        p += 1
        out = []
        for _ in self.classes[cid]["refs"]:
            ln = struct.unpack_from("<I", d, p)[0]
            out.append(bytes(d[p + 4 : p + 4 + ln]))
            p += 4 + ln
        return out

    def set_strings(self, cid, pname, values):
        ch = self.props[(cid, pname)]
        d = ch.data
        nlen = struct.unpack_from("<I", d, 4)[0]
        head = d[: 9 + nlen]
        if head[-1] != 0x01:
            raise ValueError("%s is not a String property" % pname)
        body = b"".join(struct.pack("<I", len(v)) + v for v in values)
        ch.data = bytes(head) + body
        ch.dirty = True

    # ------------------------------------------------------------------ tree helpers
    def class_name(self, ref):
        return self.classes[self.ref_class[ref]]["name"]

    def path(self, ref):
        parts = []
        cur = ref
        while cur is not None and cur != -1 and cur in self.ref_class:
            parts.append(self.names.get(cur, self.class_name(cur)))
            cur = self.parent.get(cur)
        return list(reversed(parts))

    # ------------------------------------------------------------------ writing
    def save(self, path):
        out = bytearray(self.header)
        for ch in self.chunks:
            out += ch.encode()
        open(path, "wb").write(bytes(out))


# ---------------------------------------------------------------------------------------------
# read-only decoding of the other common property types (inspection / analysis tools)
# ---------------------------------------------------------------------------------------------
def _rbx_float(u):
    bits = ((u >> 1) | ((u & 1) << 31)) & 0xFFFFFFFF
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def _floats(buf, pos, count):
    raw, pos = read_interleaved_u32(buf, pos, count)
    return [_rbx_float(u) for u in raw], pos


_AXES = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (-1, 0, 0), (0, -1, 0), (0, 0, -1)]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _basic_rotation(rid):
    i = rid - 1
    r0 = _AXES[i // 6]
    r1 = _AXES[i % 6]
    r2 = _cross(r0, r1)
    return [r0[0], r0[1], r0[2], r1[0], r1[1], r1[2], r2[0], r2[1], r2[2]]


def decode_prop(place, cid, pname):
    """Values of one property for every instance of a class (list, instance order), or None."""
    ch = place.props.get((cid, pname))
    if ch is None:
        return None
    d = ch.data
    nlen = struct.unpack_from("<I", d, 4)[0]
    p = 8 + nlen
    t = d[p]
    p += 1
    n = len(place.classes[cid]["refs"])
    if t == 0x01:
        return [v.decode("utf-8", "replace") for v in place.get_strings(cid, pname)]
    if t == 0x02:
        return [bool(b) for b in d[p : p + n]]
    if t == 0x03:
        raw, _ = read_interleaved_u32(d, p, n)
        return [_untransform_i32(u) for u in raw]
    if t == 0x04:
        return _floats(d, p, n)[0]
    if t == 0x05:
        return list(struct.unpack_from("<%dd" % n, d, p))
    if t == 0x0C:
        r, p = _floats(d, p, n)
        g, p = _floats(d, p, n)
        b, p = _floats(d, p, n)
        return list(zip(r, g, b))
    if t == 0x0D:  # Vector2
        x, p = _floats(d, p, n)
        y, p = _floats(d, p, n)
        return list(zip(x, y))
    if t == 0x0E:
        x, p = _floats(d, p, n)
        y, p = _floats(d, p, n)
        z, p = _floats(d, p, n)
        return list(zip(x, y, z))
    if t == 0x10:
        rots = []
        for _ in range(n):
            rid = d[p]
            p += 1
            if rid == 0:
                rots.append(list(struct.unpack_from("<9f", d, p)))
                p += 36
            else:
                rots.append(_basic_rotation(rid))
        x, p = _floats(d, p, n)
        y, p = _floats(d, p, n)
        z, p = _floats(d, p, n)
        return [(pos, rot) for pos, rot in zip(zip(x, y, z), rots)]
    if t == 0x12:
        raw, _ = read_interleaved_u32(d, p, n)
        return raw
    if t == 0x13:
        return read_referents(d, p, n)[0]
    if t == 0x1A:
        return list(zip(d[p : p + n], d[p + n : p + 2 * n], d[p + 2 * n : p + 3 * n]))
    if t == 0x15:  # NumberSequence
        out = []
        for _ in range(n):
            k = struct.unpack_from("<I", d, p)[0]
            p += 4
            out.append([struct.unpack_from("<3f", d, p + 12 * j) for j in range(k)])
            p += 12 * k
        return out
    if t == 0x16:  # ColorSequence
        out = []
        for _ in range(n):
            k = struct.unpack_from("<I", d, p)[0]
            p += 4
            out.append([struct.unpack_from("<5f", d, p + 20 * j) for j in range(k)])
            p += 20 * k
        return out
    if t == 0x17:  # NumberRange
        return [struct.unpack_from("<2f", d, p + 8 * j) for j in range(n)]
    if t == 0x22:  # Content: a source type per instance, then the uri strings, then object refs
        kinds, q = read_interleaved_u32(d, p, n)
        kinds = [_untransform_i32(u) for u in kinds]
        uris = []
        cnt = struct.unpack_from("<I", d, q)[0]
        q += 4
        for _ in range(cnt):
            ln = struct.unpack_from("<I", d, q)[0]
            uris.append(d[q + 4 : q + 4 + ln].decode("utf-8", "replace"))
            q += 4 + ln
        out, ui = [], 0
        for k in kinds:
            if k == 1 and ui < len(uris):
                out.append(uris[ui])
                ui += 1
            else:
                out.append("")
        return out
    return [("type", t)] * n


def instances_of(place, class_name):
    """[(cid, index, ref)] for every instance of a class."""
    out = []
    for cid, info in place.classes.items():
        if info["name"] == class_name:
            for i, r in enumerate(info["refs"]):
                out.append((cid, i, r))
    return out


def decode_attributes(blob):
    """Instance.AttributesSerialize -> {name: value} (the common attribute types)."""
    if not blob:
        return {}
    d = blob if isinstance(blob, (bytes, bytearray)) else blob.encode("latin-1")
    out = {}
    n = struct.unpack_from("<I", d, 0)[0]
    p = 4
    for _ in range(n):
        ln = struct.unpack_from("<I", d, p)[0]
        name = d[p + 4 : p + 4 + ln].decode("utf-8", "replace")
        p += 4 + ln
        t = d[p]
        p += 1
        if t == 0x02:
            ln = struct.unpack_from("<I", d, p)[0]
            v = d[p + 4 : p + 4 + ln].decode("utf-8", "replace")
            p += 4 + ln
        elif t == 0x03:
            v = bool(d[p])
            p += 1
        elif t == 0x04:
            v = struct.unpack_from("<i", d, p)[0]
            p += 4
        elif t == 0x05:
            v = struct.unpack_from("<f", d, p)[0]
            p += 4
        elif t == 0x06:
            v = struct.unpack_from("<d", d, p)[0]
            p += 8
        elif t == 0x09:
            v = struct.unpack_from("<fi", d, p)
            p += 8
        elif t == 0x0A:
            v = struct.unpack_from("<fifi", d, p)
            p += 16
        elif t == 0x0E:
            v = struct.unpack_from("<I", d, p)[0]
            p += 4
        elif t == 0x0F:
            v = struct.unpack_from("<3f", d, p)
            p += 12
        elif t == 0x10:
            v = struct.unpack_from("<2f", d, p)
            p += 8
        elif t == 0x11:
            v = struct.unpack_from("<3f", d, p)
            p += 12
        elif t == 0x15:
            ln = struct.unpack_from("<I", d, p)[0]
            v = (d[p + 4 : p + 4 + ln].decode(), struct.unpack_from("<I", d, p + 4 + ln)[0])
            p += 8 + ln
        elif t == 0x17:
            k = struct.unpack_from("<I", d, p)[0]
            v = [struct.unpack_from("<3f", d, p + 4 + 12 * j) for j in range(k)]
            p += 4 + 12 * k
        elif t == 0x19:
            k = struct.unpack_from("<I", d, p)[0]
            v = [struct.unpack_from("<5f", d, p + 4 + 20 * j) for j in range(k)]
            p += 4 + 20 * k
        elif t == 0x1B:
            v = struct.unpack_from("<2f", d, p)
            p += 8
        elif t == 0x1C:
            v = struct.unpack_from("<4f", d, p)
            p += 16
        else:
            out[name] = ("unknown type", t)
            break
        out[name] = v
    return out


def encode_attributes(attrs):
    """{name: value} -> AttributesSerialize bytes (str, bool and numbers as Float64)."""
    if not attrs:
        return b""
    out = bytearray(struct.pack("<I", len(attrs)))
    for name, v in attrs.items():
        nb = name.encode()
        out += struct.pack("<I", len(nb)) + nb
        if isinstance(v, bool):
            out += b"\x03" + bytes([1 if v else 0])
        elif isinstance(v, (int, float)):
            out += b"\x06" + struct.pack("<d", float(v))
        elif isinstance(v, str):
            vb = v.encode()
            out += b"\x02" + struct.pack("<I", len(vb)) + vb
        else:
            raise ValueError("attribute type not supported: %r" % (v,))
    return bytes(out)


# ---------------------------------------------------------------------------------------------
# structural edits: reparent, rename, clone an instance (new scripts / folders)
# ---------------------------------------------------------------------------------------------
# property types stored as `arrays` byte-interleaved columns of `width` bytes per value
_COLUMNS = {0x03: (1, 4), 0x04: (1, 4), 0x0C: (3, 4), 0x0E: (3, 4), 0x12: (1, 4), 0x1B: (1, 8), 0x1C: (1, 4), 0x1F: (1, 16), 0x21: (1, 8)}


def _deinterleave(buf, pos, count, width):
    vals = []
    for i in range(count):
        vals.append(bytes(buf[pos + j * count + i] for j in range(width)))
    return vals, pos + width * count


def _interleave(vals, width):
    n = len(vals)
    out = bytearray(width * n)
    for i, v in enumerate(vals):
        for j in range(width):
            out[j * n + i] = v[j]
    return bytes(out)


def _prop_head(ch):
    nlen = struct.unpack_from("<I", ch.data, 4)[0]
    return 8 + nlen + 1  # payload starts after the type byte


def _set_parent_entry(self, ref, parent_ref):
    ch = next(c for c in self.chunks if c.name == b"PRNT")
    d = ch.data
    count = struct.unpack_from("<I", d, 1)[0]
    kids, p = read_referents(d, 5, count)
    pars, _ = read_referents(d, p, count)
    if ref in kids:
        pars[kids.index(ref)] = parent_ref
    else:
        kids.append(ref)
        pars.append(parent_ref)
    ch.data = bytes(d[:1]) + struct.pack("<I", len(kids)) + write_referents(kids) + write_referents(pars)
    ch.dirty = True
    old = self.parent.get(ref)
    if old is not None and ref in self.children.get(old, []):
        self.children[old].remove(ref)
    self.parent[ref] = parent_ref
    self.children.setdefault(parent_ref, []).append(ref)


def _set_name(self, ref, name):
    cid = self.ref_class[ref]
    idx = self.classes[cid]["refs"].index(ref)
    vals = self.get_strings(cid, "Name")
    vals[idx] = name.encode()
    self.set_strings(cid, "Name", vals)
    self.names[ref] = name


def _find(self, path):
    """the instance at a slash path from a service ("ReplicatedStorage/Combat/VFX"), or None"""
    parts = path.split("/")
    cur = [r for r in self.ref_class if self.parent.get(r, -1) == -1 and self.names.get(r) == parts[0]]
    for name in parts[1:]:
        cur = [k for c in cur for k in self.children.get(c, []) if self.names.get(k) == name]
    return cur[0] if cur else None


def _clone_instance(self, src_ref, parent_ref, name=None):
    """a copy of one instance (its own properties only, no children) under parent_ref; returns the
    new referent. UniqueId / HistoryId get fresh values."""
    import os as _os

    cid = self.ref_class[src_ref]
    info = self.classes[cid]
    idx = info["refs"].index(src_ref)
    n = len(info["refs"])
    new_ref = max(self.ref_class) + 1
    for (pcid, pname), ch in self.props.items():
        if pcid != cid:
            continue
        d = ch.data
        head = _prop_head(ch)
        t = d[head - 1]
        body = d[head:]
        if t == 0x01:
            vals = self.get_strings(cid, pname)
            v = vals[idx]
            if pname == "Name" and name is not None:
                v = name.encode()
            vals.append(v)
            new_body = b"".join(struct.pack("<I", len(x)) + x for x in vals)
        elif t == 0x02:
            new_body = bytes(body[:n]) + bytes([body[idx]])
        elif t in _COLUMNS:
            arrays, width = _COLUMNS[t]
            out = b""
            pos = 0
            for _ in range(arrays):
                vals, pos = _deinterleave(body, pos, n, width)
                v = vals[idx]
                if t == 0x1F:
                    v = _os.urandom(8) + v[8:]
                vals.append(v)
                out += _interleave(vals, width)
            new_body = out
        else:
            raise ValueError("clone: property %s type 0x%02x not supported" % (pname, t))
        ch.data = bytes(d[:head]) + new_body
        ch.dirty = True
    # the class's instance list
    ich = info["chunk"]
    d = ich.data
    nlen = struct.unpack_from("<I", d, 4)[0]
    p = 8 + nlen
    fmt = d[p]
    refs = info["refs"] + [new_ref]
    extra = b""
    if fmt:  # service markers follow the referents
        extra = bytes(d[p + 5 + 4 * n : p + 5 + 5 * n]) + b"\x00"
    ich.data = bytes(d[: p + 1]) + struct.pack("<I", len(refs)) + write_referents(refs) + extra
    ich.dirty = True
    info["refs"] = refs
    self.ref_class[new_ref] = cid
    self.names[new_ref] = name if name is not None else self.names.get(src_ref, "")
    self.inst_count += 1
    self.header = self.header[:14] + struct.pack("<HII", self.version, self.class_count, self.inst_count) + self.header[24:]
    _set_parent_entry(self, new_ref, parent_ref)
    return new_ref


Place.set_parent = _set_parent_entry
Place.set_name = _set_name
Place.find = _find
Place.clone_instance = _clone_instance
