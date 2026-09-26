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
