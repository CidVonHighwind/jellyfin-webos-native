#!/usr/bin/env python3
"""Grab one frame from the TV's VNC server and write it as a PNG.

    tools/vncshot.py <host> <out.png> [password]

This is how on-device rendering gets checked from the dev machine: webOS has no
screenshot service a native app can reach (luna's capture methods silently do
nothing -- see docs/device.md), but the TV runs LibVNCServer on 5900.

`zig build shot` wraps this with the host and password from .env.

Raw encoding only, one full update, no input -- deliberately the smallest thing
that produces a picture. Needs pycryptodome for the DES in VNC's password auth.
"""
import socket, struct, sys, zlib

from Crypto.Cipher import DES

host, out = sys.argv[1], sys.argv[2]
password = sys.argv[3] if len(sys.argv) > 3 else None
s = socket.create_connection((host, 5900), 10); s.settimeout(20)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError(f"short read {len(b)}/{n}")
        b += c
    return b
ver = rd(12); print("server", ver)
s.sendall(b"RFB 003.008\n")
n = rd(1)[0]; types = rd(n); print("security", list(types))
if 1 in types:
    s.sendall(b"\x01")
elif 2 in types:
    if not password: raise SystemExit("server wants a password; pass it as argv[3]")
    s.sendall(b"\x02")
    challenge = rd(16)
    # VNC auth: DES with each key byte's bits reversed, two ECB blocks.
    key = password.encode()[:8].ljust(8, b"\0")
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in key)
    s.sendall(DES.new(key, DES.MODE_ECB).encrypt(challenge))
else:
    raise SystemExit(f"unsupported security types {list(types)}")
res = struct.unpack(">I", rd(4))[0]
if res != 0:
    nl = struct.unpack(">I", rd(4))[0] if b"008" in ver else 0
    raise SystemExit(f"auth failed: {rd(nl) if nl else res}")
s.sendall(b"\x01")  # shared
w, h = struct.unpack(">HH", rd(4))
pf = rd(16); nl = struct.unpack(">I", rd(4))[0]; name = rd(nl)
bpp, depth, big, true = pf[0], pf[1], pf[2], pf[3]
rmax, gmax, bmax = struct.unpack(">HHH", pf[4:10])
rs, gs, bs = pf[10], pf[11], pf[12]
print(f"{w}x{h} bpp={bpp} depth={depth} true={true} shifts={rs},{gs},{bs} name={name}")
s.sendall(struct.pack(">BBHi", 2, 0, 1, 0))          # SetEncodings: raw
s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))  # full update
msg = rd(1)[0]
assert msg == 0, msg
rd(1); nrect = struct.unpack(">H", rd(2))[0]
img = bytearray(w * h * 3)
for _ in range(nrect):
    x, y, rw, rh, enc = struct.unpack(">HHHHi", rd(12))
    print("rect", x, y, rw, rh, "enc", enc)
    if enc != 0: raise SystemExit("non-raw encoding")
    data = rd(rw * rh * bpp // 8)
    step = bpp // 8
    for row in range(rh):
        for col in range(rw):
            px = int.from_bytes(data[(row * rw + col) * step:][:step], "big" if big else "little")
            o = ((y + row) * w + (x + col)) * 3
            img[o] = (px >> rs) & rmax
            img[o + 1] = (px >> gs) & gmax
            img[o + 2] = (px >> bs) & bmax
raw = b''.join(b'\x00' + bytes(img[r * w * 3:(r + 1) * w * 3]) for r in range(h))
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
open(out, 'wb').write(png)
print("wrote", out, len(png), "bytes")
import socket, struct, sys, zlib

from Crypto.Cipher import DES

host, out = sys.argv[1], sys.argv[2]
password = sys.argv[3] if len(sys.argv) > 3 else None
s = socket.create_connection((host, 5900), 10); s.settimeout(20)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError(f"short read {len(b)}/{n}")
        b += c
    return b
ver = rd(12); print("server", ver)
s.sendall(b"RFB 003.008\n")
n = rd(1)[0]; types = rd(n); print("security", list(types))
if 1 in types:
    s.sendall(b"\x01")
elif 2 in types:
    if not password: raise SystemExit("server wants a password; pass it as argv[3]")
    s.sendall(b"\x02")
    challenge = rd(16)
    # VNC auth: DES with each key byte's bits reversed, two ECB blocks.
    key = password.encode()[:8].ljust(8, b"\0")
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in key)
    s.sendall(DES.new(key, DES.MODE_ECB).encrypt(challenge))
else:
    raise SystemExit(f"unsupported security types {list(types)}")
res = struct.unpack(">I", rd(4))[0]
if res != 0:
    nl = struct.unpack(">I", rd(4))[0] if b"008" in ver else 0
    raise SystemExit(f"auth failed: {rd(nl) if nl else res}")
s.sendall(b"\x01")  # shared
w, h = struct.unpack(">HH", rd(4))
pf = rd(16); nl = struct.unpack(">I", rd(4))[0]; name = rd(nl)
bpp, depth, big, true = pf[0], pf[1], pf[2], pf[3]
rmax, gmax, bmax = struct.unpack(">HHH", pf[4:10])
rs, gs, bs = pf[10], pf[11], pf[12]
print(f"{w}x{h} bpp={bpp} depth={depth} true={true} shifts={rs},{gs},{bs} name={name}")
s.sendall(struct.pack(">BBHi", 2, 0, 1, 0))          # SetEncodings: raw
s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))  # full update
msg = rd(1)[0]
assert msg == 0, msg
rd(1); nrect = struct.unpack(">H", rd(2))[0]
img = bytearray(w * h * 3)
for _ in range(nrect):
    x, y, rw, rh, enc = struct.unpack(">HHHHi", rd(12))
    print("rect", x, y, rw, rh, "enc", enc)
    if enc != 0: raise SystemExit("non-raw encoding")
    data = rd(rw * rh * bpp // 8)
    step = bpp // 8
    for row in range(rh):
        for col in range(rw):
            px = int.from_bytes(data[(row * rw + col) * step:][:step], "big" if big else "little")
            o = ((y + row) * w + (x + col)) * 3
            img[o] = (px >> rs) & rmax
            img[o + 1] = (px >> gs) & gmax
            img[o + 2] = (px >> bs) & bmax
raw = b''.join(b'\x00' + bytes(img[r * w * 3:(r + 1) * w * 3]) for r in range(h))
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
open(out, 'wb').write(png)
print("wrote", out, len(png), "bytes")
