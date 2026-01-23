"""UDP server for Omphalos headless game logic."""
import asyncio
import json
import math
import time
from typing import Any, Dict, List, Optional, Tuple

from noise import pnoise2


def _now_ms() -> int:
    return int(time.time() * 1000)


def _clamp_int(value: Any, lo: int, hi: int, default: int = 0) -> int:
    try:
        return max(lo, min(hi, int(value)))
    except (TypeError, ValueError):
        return default


class OmphalosUdpServer(asyncio.DatagramProtocol):
    """
    UDP server for headless game logic.

    Communication concerns (UDP):
    - Packet loss: client should resend inputs; server is stateless per message.
    - Ordering/duplication: client includes seq; server ignores older packets.
    - Latency spikes: server returns server_time_ms to help interpolation.
    - Heartbeats: client should ping; server replies with latest snapshot.
    - Reconnect/backoff: client can re-init by sending "hello".
    - Validation: malformed payloads are ignored.
    - Graceful degradation: if no input, server still ticks the world.
    """

    def __init__(self, tick_hz: int = 30, snapshot_hz: int = 10):
        super().__init__()
        self.tick_interval = 1.0 / max(1, tick_hz)
        self.snapshot_interval = 1.0 / max(1, snapshot_hz)
        self.transport: Optional[asyncio.DatagramTransport] = None
        self.last_seq: Dict[Tuple[str, int], int] = {}
        self.last_snapshot: Dict[Tuple[str, int], bytes] = {}
        self.clients: Dict[Tuple[str, int], float] = {}
        self._last_snapshot_time = 0.0
        self._known_clients: set[Tuple[str, int]] = set()
        self._last_tick_log = 0.0

        # World + player state (owned by server)
        self.player_x = 0.0
        self.player_z = 0.0
        self.player_y = 0.0
        self.player_facing = 0.0
        self.move_speed = 8.0
        self.turn_speed = 2.5

        self.chunk_size = 32.0
        self.chunk_resolution = 32
        self.view_distance_chunks = 3
        self.height_amplitude = 8.0
        self.noise_frequency = 0.02
        self.noise_seed = 1337

        self.last_input: Dict[Tuple[str, int], Dict[str, Any]] = {}
        self.chunk_cache: Dict[Tuple[int, int], List[float]] = {}
        self.chunk_cursor: Dict[Tuple[str, int], int] = {}

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]
        print("Omphalos UDP server started")

    def datagram_received(self, data: bytes, addr) -> None:
        try:
            message = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return

        msg_type = message.get("type")
        seq = _clamp_int(message.get("seq", 0), 0, 1_000_000_000, 0)

        last = self.last_seq.get(addr, -1)
        if seq < last:
            return
        if seq == last:
            cached = self.last_snapshot.get(addr)
            if cached and self.transport:
                self.transport.sendto(cached, addr)
            return

        self.last_seq[addr] = seq
        self.clients[addr] = time.time()
        if addr not in self._known_clients:
            self._known_clients.add(addr)
            print(f"UDP client connected: {addr}")

        if msg_type == "hello":
            self._send_snapshot(addr, seq, note="hello")
            return
        if msg_type == "ping":
            self._send_snapshot(addr, seq, note="pong")
            return
        if msg_type == "input":
            payload = message.get("payload", {})
            self.last_input[addr] = payload
            self._send_snapshot(addr, seq, note="input_ack")
            return

    def _apply_input(self, payload: Dict[str, Any]) -> None:
        turn = float(payload.get("turn", 0.0))
        move = float(payload.get("move", 0.0))

        if turn != 0.0:
            self.player_facing -= turn * self.turn_speed * self.tick_interval

        if move != 0.0:
            forward_x = math.sin(self.player_facing)
            forward_z = math.cos(self.player_facing)
            self.player_x += forward_x * move * self.move_speed * self.tick_interval
            self.player_z += forward_z * move * self.move_speed * self.tick_interval

        self.player_y = self._get_height(self.player_x, self.player_z)

    def _snapshot(self) -> Dict[str, Any]:
        return {
            "server_time_ms": _now_ms(),
            "player": {
                "x": self.player_x,
                "y": self.player_y,
                "z": self.player_z,
                "facing": self.player_facing,
            },
            "terrain": {
                "chunk_size": self.chunk_size,
                "chunk_resolution": self.chunk_resolution,
                "view_distance_chunks": self.view_distance_chunks,
            },
        }

    def _send_snapshot(self, addr, seq: int, note: str = "") -> None:
        if not self.transport:
            return
        payload = {
            "type": "state",
            "seq": seq,
            "note": note,
            "payload": self._snapshot(),
        }
        encoded = json.dumps(payload).encode("utf-8")
        self.last_snapshot[addr] = encoded
        self.transport.sendto(encoded, addr)

    async def tick_loop(self) -> None:
        while True:
            for addr, payload in list(self.last_input.items()):
                self._apply_input(payload)

            now = time.time()
            if now - self._last_snapshot_time >= self.snapshot_interval:
                self._last_snapshot_time = now
                if self.transport:
                    for addr in list(self.clients.keys()):
                        seq = self.last_seq.get(addr, 0)
                        if seq == 0:
                            seq = 1
                        self._send_snapshot(addr, seq, note="tick")
                        self._send_next_chunk(addr, seq)

            if now - self._last_tick_log >= 2.0:
                self._last_tick_log = now
                print(f"Tick: clients={len(self.clients)} last_seq={self.last_seq}")

            await asyncio.sleep(self.tick_interval)

    def _get_height(self, x: float, z: float) -> float:
        return (
            pnoise2(x * self.noise_frequency, z * self.noise_frequency, octaves=4, base=self.noise_seed)
            * self.height_amplitude
        )

    def _get_visible_chunks(self) -> List[Dict[str, Any]]:
        cx = int(self.player_x // self.chunk_size)
        cz = int(self.player_z // self.chunk_size)
        chunks: List[Dict[str, Any]] = []
        for x in range(cx - self.view_distance_chunks, cx + self.view_distance_chunks + 1):
            for z in range(cz - self.view_distance_chunks, cz + self.view_distance_chunks + 1):
                heights = self._get_chunk_heights(x, z)
                chunks.append({"cx": x, "cz": z, "heights": heights})
        return chunks

    def _send_next_chunk(self, addr: Tuple[str, int], seq: int) -> None:
        if not self.transport:
            return
        visible = self._get_visible_chunks()
        if not visible:
            return
        cursor = self.chunk_cursor.get(addr, 0) % len(visible)
        chunk = visible[cursor]
        self.chunk_cursor[addr] = cursor + 1
        payload = {
            "type": "chunk",
            "seq": seq,
            "payload": {
                "cx": chunk["cx"],
                "cz": chunk["cz"],
                "chunk_size": self.chunk_size,
                "chunk_resolution": self.chunk_resolution,
                "heights": chunk["heights"],
            },
        }
        encoded = json.dumps(payload).encode("utf-8")
        self.transport.sendto(encoded, addr)

    def _get_chunk_heights(self, cx: int, cz: int) -> List[float]:
        key = (cx, cz)
        if key in self.chunk_cache:
            return self.chunk_cache[key]

        heights: List[float] = []
        step = self.chunk_size / float(self.chunk_resolution)
        for z in range(self.chunk_resolution + 1):
            for x in range(self.chunk_resolution + 1):
                world_x = (cx * self.chunk_size) + (x * step)
                world_z = (cz * self.chunk_size) + (z * step)
                heights.append(self._get_height(world_x, world_z))

        self.chunk_cache[key] = heights
        return heights


async def main(host: str = "0.0.0.0", port: int = 7777, tick_hz: int = 30):
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        lambda: OmphalosUdpServer(tick_hz=tick_hz),
        local_addr=(host, port),
    )
    try:
        await protocol.tick_loop()  # type: ignore[union-attr]
    finally:
        transport.close()


if __name__ == "__main__":
    asyncio.run(main())
