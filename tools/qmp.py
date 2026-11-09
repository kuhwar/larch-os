#!/usr/bin/env python3
"""Minimal QEMU QMP client for test-auto.sh (standard library only).

  qmp.py <socket> screendump <out.png>   screenshot (also leaves <out.png>.ppm)
  qmp.py <socket> sendkey <key>...       press keys in order; a key is a QEMU
                                         qcode, chords joined with '-' (shift-a)
  qmp.py <socket> <command>              any argument-less QMP command
                                         (system_powerdown, quit, …)
"""
import json
import socket
import struct
import sys
import time
import zlib


def qmp(sock_path, cmd, args=None):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    f = s.makefile("rw")
    json.loads(f.readline())                       # greeting
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    f.readline()
    msg = {"execute": cmd}
    if args:
        msg["arguments"] = args
    f.write(json.dumps(msg) + "\n")
    f.flush()
    while True:                                    # skip asynchronous events
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            s.close()
            return r


def ppm_to_png(ppm_path, png_path):
    data = open(ppm_path, "rb").read()
    magic, w, h, _maxval, pixels = data.split(maxsplit=4)
    assert magic == b"P6", "screendump is not a binary PPM"
    w, h = int(w), int(h)
    raw = b"".join(b"\x00" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    open(png_path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b""))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sock, cmd = sys.argv[1], sys.argv[2]
    if cmd == "screendump":
        ppm = sys.argv[3] + ".ppm"
        r = qmp(sock, "screendump", {"filename": ppm})
        time.sleep(0.5)
        ppm_to_png(ppm, sys.argv[3])
    elif cmd == "sendkey":
        for k in sys.argv[3:]:
            r = qmp(sock, "send-key",
                    {"keys": [{"type": "qcode", "data": q} for q in k.split("-")]})
            time.sleep(0.15)
    else:
        r = qmp(sock, cmd)
    if "error" in r:
        sys.exit(f"QMP {cmd}: {r['error']}")


if __name__ == "__main__":
    main()
