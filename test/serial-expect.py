#!/usr/bin/env python3
"""Drive a QEMU serial console on a unix socket: wait for text, send keys.

    serial-expect.py SOCKET TIMEOUT 'expect=>send' ['expect=>send' ...]

Everything received is echoed to stdout. Exits 1 if an expected string does
not show up within TIMEOUT seconds.
"""
import socket
import sys
import time

path, timeout, steps = sys.argv[1], float(sys.argv[2]), sys.argv[3:]

deadline = time.time() + 30
while True:
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(path)
        break
    except OSError:
        if time.time() > deadline:
            sys.exit(f"cannot connect to {path}")
        time.sleep(0.5)

s.settimeout(1)
buf = ""
for step in steps:
    want, _, send = step.partition("=>")
    end = time.time() + timeout
    while want not in buf:
        if time.time() > end:
            sys.exit(f"\ntimeout waiting for {want!r}")
        try:
            data = s.recv(4096).decode(errors="replace")
        except socket.timeout:
            continue
        if not data:
            sys.exit(f"\nconsole closed while waiting for {want!r}")
        sys.stdout.write(data)
        sys.stdout.flush()
        buf += data
    buf = buf[buf.index(want) + len(want):]
    time.sleep(0.5)
    s.sendall(send.encode())
