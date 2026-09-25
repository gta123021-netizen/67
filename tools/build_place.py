#!/usr/bin/env python3
"""Write the scripts in src/ back into a Roblox place file.

    python3 tools/build_place.py <in.rbxlx> <src dir> <out.rbxlx>

Every script whose path in the game tree is unique and whose file in src/ differs from the
source in the place gets the file's source. Everything else in the place is copied through
byte for byte. File names are the script's path joined with "__" (spaces become "_") plus
.server.lua / .client.lua / .lua, the same names src/ was extracted with.
"""
import html
import os
import re
import sys
import xml.etree.ElementTree as ET

EXT = {"Script": ".server.lua", "LocalScript": ".client.lua", "ModuleScript": ".lua"}
TOKEN = re.compile(
    r'<!\[CDATA\[.*?\]\]>'
    r'|<Item class="([^"]*)"[^>]*>'
    r'|</Item>'
    r'|<string name="Name">(.*?)</string>'
    r'|<ProtectedString name="Source">',
    re.S,
)
BODY = re.compile(r'((?:<!\[CDATA\[.*?\]\]>)*)</ProtectedString>', re.S)
CDATA = re.compile(r'<!\[CDATA\[(.*?)\]\]>', re.S)


def file_name(path, cls):
    return "__".join(path).replace("/", "_").replace(" ", "_") + EXT.get(cls, ".lua")


def scan(data):
    """Return (path, class, body_start, body_end, source) for every script Source in the place.
    An item's Name can come after its Source, so paths are resolved once the scan is done."""
    stack = []
    found = []
    pos = 0
    while True:
        m = TOKEN.search(data, pos)
        if not m:
            break
        tok = m.group(0)
        pos = m.end()
        if tok.startswith("<![CDATA["):
            continue
        if tok.startswith("<Item"):
            stack.append([m.group(1), None])
        elif tok == "</Item>":
            stack.pop()
        elif tok.startswith("<string"):
            if stack and stack[-1][1] is None:
                stack[-1][1] = html.unescape(m.group(2))
        else:
            b = BODY.match(data, pos)
            if not b:
                raise SystemExit("Source without CDATA at offset %d" % pos)
            source = "".join(CDATA.findall(b.group(1)))
            found.append((list(stack), pos, pos + len(b.group(1)), source))
            pos = b.end()
    out = []
    for entries, start, end, source in found:
        path = [n if n is not None else c for c, n in entries]
        out.append((path, entries[-1][0], start, end, source))
    return out


def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def main():
    src_path, src_dir, out_path = sys.argv[1:4]
    data = open(src_path, encoding="utf-8", newline="").read()
    scripts = scan(data)
    counts = {}
    for path, cls, *_ in scripts:
        key = "/".join(path)
        counts[key] = counts.get(key, 0) + 1

    edits = []
    for path, cls, start, end, source in scripts:
        fn = os.path.join(src_dir, file_name(path, cls))
        if counts["/".join(path)] != 1 or not os.path.exists(fn):
            continue
        new = open(fn, encoding="utf-8", newline="").read()
        if new != source:
            edits.append((start, end, cdata(new), "/".join(path)))

    out = []
    last = 0
    for start, end, text, name in sorted(edits):
        out.append(data[last:start])
        out.append(text)
        last = end
        print("updated", name)
    out.append(data[last:])
    result = "".join(out)

    # the result must still be a valid place, and read back exactly what src/ holds
    ET.fromstring(result.encode("utf-8"))
    for path, cls, start, end, source in scan(result):
        fn = os.path.join(src_dir, file_name(path, cls))
        if counts["/".join(path)] == 1 and os.path.exists(fn):
            assert source == open(fn, encoding="utf-8", newline="").read(), "/".join(path)
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        f.write(result)
    print("%d scripts, %d updated -> %s" % (len(scripts), len(edits), out_path))


if __name__ == "__main__":
    main()
