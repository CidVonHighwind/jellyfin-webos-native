#!/usr/bin/env python3
"""Regenerate src/jellyfin/testdata/gradient.png.

A checked-in binary fixture needs a way to be rebuilt. This one is deliberately
filtered (Sub on even rows, Paeth on odd) so the decoder test covers more than
an unfiltered image.
"""
import zlib, struct, sys

w = h = 16
raw, prev = b"", bytearray(w * 3)
for y in range(h):
    row = bytearray()
    for x in range(w):
        row += bytes((x * 16, y * 16, 64))
    out = bytearray(row)
    if y % 2 == 0:
        f = 1
        for i in range(len(row)):
            out[i] = (row[i] - (row[i - 3] if i >= 3 else 0)) & 0xFF
    else:
        f = 4
        for i in range(len(row)):
            a = row[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            out[i] = (row[i] - pr) & 0xFF
    raw += bytes([f]) + bytes(out)
    prev = row


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw))
    + chunk(b"IEND", b"")
)
path = sys.argv[1] if len(sys.argv) > 1 else "src/jellyfin/testdata/gradient.png"
open(path, "wb").write(png)
print(f"wrote {path} ({len(png)} bytes)")
