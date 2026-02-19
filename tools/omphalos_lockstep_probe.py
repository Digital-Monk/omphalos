#!/usr/bin/env python3
"""Omphalos lock-step probe client (stdlib-only).

Purpose
- Validate server responsiveness and ordering without Godot.
- Talks to the TCP lock-step chunk server (omphalos_tcp_server).
- Requests N most-important chunks, waits for BatchEnd, repeats.

Protocol
- Same binary frame header used by the project:
    [magic u32][ver u8][type u8][seq u32][payload_len u32] + payload
- Uses the MSG_WANT payload layout (single fragment only).
- TCP-only messages:
    MSG_INFO (7): [batch_n u32][chunk_size f32][chunk_res i32][view_dist i32][height_amp f32]
    MSG_BATCH_END (8): [count u32]

Run
- Start server:  server/build/omphalos_tcp_server 7778 12
- Probe:         python3 tools/omphalos_lockstep_probe.py --host 127.0.0.1 --port 7778

"""

from __future__ import annotations

import argparse
import math
import socket
import struct
import time
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Set, Tuple

NET_MAGIC = 0x4F4D5048  # 'OMPH'
NET_VERSION = 1

MSG_HELLO = 1
MSG_WANT = 6
MSG_INFO = 7
MSG_BATCH_END = 8
MSG_CHUNK = 5

HEADER_FMT = "<IBBII"  # magic,u8 ver,u8 type,u32 seq,u32 payload_len
HEADER_SIZE = struct.calcsize(HEADER_FMT)  # 14


@dataclass
class ServerInfo:
    batch_n: int
    chunk_size: float
    chunk_resolution: int
    view_distance_chunks: int
    height_amplitude: float


def pack_frame(msg_type: int, seq: int, payload: bytes) -> bytes:
    return struct.pack(HEADER_FMT, NET_MAGIC, NET_VERSION, msg_type, seq, len(payload)) + payload


def want_payload(gen: int, pcx: int, pcz: int, entries: List[Tuple[int, int]]) -> bytes:
    # [gen u32][part u8=0][total u8=1][pcx i32][pcz i32][count u32][(dx i16,dz i16)*]
    hdr = struct.pack("<IBBiiI", gen & 0xFFFFFFFF, 0, 1, pcx, pcz, len(entries))
    body = b"".join(struct.pack("<hh", dx, dz) for dx, dz in entries)
    return hdr + body


def iter_offsets_in_radius(r: int) -> Iterable[Tuple[int, int, int]]:
    r2 = r * r
    for dx in range(-r, r + 1):
        dx2 = dx * dx
        for dz in range(-r, r + 1):
            d2 = dx2 + dz * dz
            if d2 <= r2:
                yield dx, dz, d2


def build_sorted_offsets(radius: int) -> List[Tuple[int, int, int]]:
    offsets = list(iter_offsets_in_radius(radius))
    offsets.sort(key=lambda t: t[2])
    return offsets


class FrameStream:
    def __init__(self) -> None:
        self.buf = bytearray()

    def feed(self, data: bytes) -> None:
        self.buf += data

    def pop(self) -> Optional[Tuple[int, int, bytes]]:
        if len(self.buf) < HEADER_SIZE:
            return None
        magic, ver, msg_type, seq, plen = struct.unpack_from(HEADER_FMT, self.buf, 0)
        if magic != NET_MAGIC or ver != NET_VERSION:
            raise ValueError(f"Bad header magic/ver: magic={magic:x} ver={ver}")
        frame_len = HEADER_SIZE + plen
        if len(self.buf) < frame_len:
            return None
        payload = bytes(self.buf[HEADER_SIZE:frame_len])
        del self.buf[:frame_len]
        return int(msg_type), int(seq), payload


def parse_info(payload: bytes) -> Optional[ServerInfo]:
    if len(payload) < 20:
        return None
    batch_n, = struct.unpack_from("<I", payload, 0)
    chunk_size, = struct.unpack_from("<f", payload, 4)
    chunk_res, = struct.unpack_from("<i", payload, 8)
    view_dist, = struct.unpack_from("<i", payload, 12)
    height_amp, = struct.unpack_from("<f", payload, 16)
    return ServerInfo(
        batch_n=int(batch_n),
        chunk_size=float(chunk_size),
        chunk_resolution=int(chunk_res),
        view_distance_chunks=int(view_dist),
        height_amplitude=float(height_amp),
    )


def parse_chunk_key(payload: bytes) -> Optional[Tuple[int, int]]:
    if len(payload) < 8:
        return None
    cx, cz = struct.unpack_from("<ii", payload, 0)
    return int(cx), int(cz)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7778)
    ap.add_argument("--radius", type=int, default=150)
    ap.add_argument("--pcx", type=int, default=0)
    ap.add_argument("--pcz", type=int, default=0)
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--batch", type=int, default=0, help="Override server batch_n (0=use server) ")
    ap.add_argument("--jump-every", type=int, default=0, help="Every N batches, move center by jump-dx/jump-dz")
    ap.add_argument("--jump-dx", type=int, default=200)
    ap.add_argument("--jump-dz", type=int, default=0)
    ap.add_argument("--print", type=int, default=20, help="Print first N chunk arrivals")
    args = ap.parse_args()

    offsets = build_sorted_offsets(args.radius)

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(2.0)
    sock.connect((args.host, args.port))
    sock.settimeout(0.2)

    fs = FrameStream()

    seq = 0

    def send(msg_type: int, payload: bytes = b"") -> int:
        nonlocal seq
        seq += 1
        sock.sendall(pack_frame(msg_type, seq, payload))
        return seq

    # Handshake.
    send(MSG_HELLO)

    info: Optional[ServerInfo] = None
    got_info_deadline = time.time() + 2.0
    while time.time() < got_info_deadline and info is None:
        try:
            data = sock.recv(65536)
        except socket.timeout:
            continue
        if not data:
            raise RuntimeError("Server closed connection before INFO")
        fs.feed(data)
        while True:
            frame = fs.pop()
            if frame is None:
                break
            msg_type, _seq, payload = frame
            if msg_type == MSG_INFO:
                info = parse_info(payload)
                break

    if info is None:
        raise RuntimeError("Did not receive MSG_INFO from server")

    batch_n = int(args.batch) if args.batch and args.batch > 0 else int(info.batch_n)
    batch_n = max(1, batch_n)

    print(
        f"INFO: batch_n={info.batch_n} using={batch_n} chunk_size={info.chunk_size} "
        f"res={info.chunk_resolution} view={info.view_distance_chunks} amp={info.height_amplitude}"
    )

    received: Set[Tuple[int, int]] = set()

    pcx = int(args.pcx)
    pcz = int(args.pcz)

    start = time.time()
    batches = 0
    printed = 0
    total_chunks = 0

    while time.time() - start < args.seconds:
        # Build N nearest missing relative to current center.
        entries: List[Tuple[int, int]] = []
        for dx, dz, _d2 in offsets:
            cx = pcx + dx
            cz = pcz + dz
            if (cx, cz) in received:
                continue
            entries.append((dx, dz))
            if len(entries) >= batch_n:
                break

        req_seq = send(MSG_WANT, want_payload(gen=seq, pcx=pcx, pcz=pcz, entries=entries))
        batches += 1

        batch_start = time.time()
        batch_chunks = 0
        batch_done = False

        # Read until BatchEnd for this request seq.
        while not batch_done:
            try:
                data = sock.recv(65536)
            except socket.timeout:
                # If server is busy, we may just be waiting.
                if time.time() - batch_start > 5.0:
                    raise RuntimeError("Timed out waiting for batch response")
                continue
            if not data:
                raise RuntimeError("Server closed connection")
            fs.feed(data)

            # Drain all complete frames currently buffered.
            while True:
                frame = fs.pop()
                if frame is None:
                    break
                msg_type, frame_seq, payload = frame
                if msg_type == MSG_CHUNK:
                    key = parse_chunk_key(payload)
                    if key is not None and key not in received:
                        received.add(key)
                        batch_chunks += 1
                        total_chunks += 1
                        if printed < args.print:
                            cx, cz = key
                            dx = cx - pcx
                            dz = cz - pcz
                            d2 = dx * dx + dz * dz
                            print(f"chunk#{total_chunks:05d} ({cx},{cz}) d2={d2}")
                            printed += 1
                elif msg_type == MSG_BATCH_END:
                    # End of this batch.
                    end_count, = struct.unpack_from("<I", payload, 0) if len(payload) >= 4 else (0,)
                    dur_ms = (time.time() - batch_start) * 1000.0
                    print(
                        f"batch#{batches:04d} req_seq={req_seq} got={batch_chunks} end_count={end_count} "
                        f"dur={dur_ms:.1f}ms center=({pcx},{pcz}) received_total={len(received)}"
                    )
                    batch_done = True
                    break



        # Optional huge movement test.
        if args.jump_every and args.jump_every > 0 and (batches % args.jump_every) == 0:
            pcx += int(args.jump_dx)
            pcz += int(args.jump_dz)

    elapsed = time.time() - start
    cps = total_chunks / max(1e-6, elapsed)
    print(f"Done: batches={batches} total_chunks={total_chunks} elapsed={elapsed:.2f}s chunks/s={cps:.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
