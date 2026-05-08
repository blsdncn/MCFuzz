#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import random
import zlib


def encode_varint(value: int) -> bytes:
    if value < 0:
        value &= 0xFFFFFFFF
    out = bytearray()
    while True:
        temp = value & 0x7F
        value >>= 7
        if value != 0:
            temp |= 0x80
        out.append(temp)
        if value == 0:
            break
    return bytes(out)


def pack_i32(value: int) -> bytes:
    value &= 0xFFFFFFFF
    return value.to_bytes(4, "big", signed=False)


def put_len_bytes(buf: bytearray, payload: bytes) -> None:
    buf.extend(pack_i32(len(payload)))
    buf.extend(payload)


def env_int(name: str, default: int, minimum=None) -> int:
    raw = os.getenv(name)
    if raw is None:
        value = default
    else:
        try:
            value = int(raw)
        except ValueError:
            value = default

    if minimum is not None:
        value = max(minimum, value)
    return value


def rand_bytes(rng: random.Random, length: int) -> bytes:
    return bytes(rng.getrandbits(8) for _ in range(max(0, length)))


def repeat_pattern(pattern: bytes, wanted: int) -> bytes:
    if wanted <= 0:
        return b""
    if not pattern:
        pattern = b"seed"
    out = bytearray()
    while len(out) < wanted:
        need = wanted - len(out)
        out.extend(pattern[:need])
    return bytes(out)


def make_frame_header(version_index: int = 3, direction_serverbound: bool = True,
                      steps: int = 4) -> bytearray:
    buf = bytearray()
    buf.extend(pack_i32(version_index))
    buf.append(1 if direction_serverbound else 0)
    buf.extend(pack_i32(steps - 1))
    return buf


def append_stateless_frame(
    buf: bytearray,
    state_selector: int,
    packet_id_selector: int,
    packet_payload: bytes,
    op_payload: bytes,
    op_index: int,
    codec_selector: int,
    codec_payload: bytes,
    next_direction_serverbound: bool,
    next_version_index: int,
) -> None:
    # Stateless target consumes explicit state selector per step.
    buf.extend(pack_i32(state_selector))
    buf.extend(pack_i32(packet_id_selector))
    put_len_bytes(buf, packet_payload)
    put_len_bytes(buf, op_payload)
    buf.extend(pack_i32(op_index))
    buf.extend(pack_i32(codec_selector))
    put_len_bytes(buf, codec_payload)
    buf.append(1 if next_direction_serverbound else 0)
    buf.extend(pack_i32(next_version_index))


def op_payload_issue_1770() -> bytes:
    channel = b"floodgate:skin"
    return encode_varint(len(channel)) + channel + repeat_pattern(b"PM", 32767 + 2048)


def op_payload_issue_1766() -> bytes:
    channel = b"floodgate:skin"
    return encode_varint(len(channel)) + channel + b"player-skin-sync"


def op_payload_issue_1742() -> bytes:
    claimed = encode_varint((8 * 1024 * 1024) - 64)
    compressed = zlib.compress(repeat_pattern(b"A", 4096), level=9)
    return claimed + compressed


def op_payload_issue_1768() -> bytes:
    out = bytearray()
    out.append(10)  # TAG_Compound
    out.extend((0).to_bytes(2, "big"))
    out.append(3)  # TAG_Int
    out.extend((1).to_bytes(2, "big"))
    out.extend(b"x")
    out.extend((1).to_bytes(4, "big", signed=True))
    out.append(0)  # TAG_End
    return bytes(out)


def payload_cookie_valid() -> bytes:
    key = b"minecraft:stone"
    body = bytearray()
    body.extend(encode_varint(len(key)))
    body.extend(key)
    body.extend(b"\x01")
    body.extend(encode_varint(16))
    body.extend(b"cookie-payload-123")
    return bytes(body)


def payload_handshake_like() -> bytes:
    out = bytearray()
    out.extend(encode_varint(766))
    host = b"some-dynamic-host-name.internal"
    out.extend(encode_varint(len(host)))
    out.extend(host)
    out.extend((25565).to_bytes(2, "big"))
    out.extend(encode_varint(2))
    return bytes(out)


def payload_status_ping_like() -> bytes:
    return (0x1122334455667788).to_bytes(8, "big", signed=False)


def seed_issue_1770_plugin_message() -> bytes:
    buf = make_frame_header(version_index=3, direction_serverbound=True, steps=4)
    for i in range(4):
        append_stateless_frame(
            buf,
            state_selector=i % 5,
            packet_id_selector=0x10 + i,
            packet_payload=payload_handshake_like() if i % 2 == 0 else payload_cookie_valid(),
            op_payload=op_payload_issue_1770(),
            op_index=10,
            codec_selector=2,
            codec_payload=op_payload_issue_1770(),
            next_direction_serverbound=True,
            next_version_index=5 + i,
        )
    return bytes(buf)


def seed_issue_1766_plugin_join_window() -> bytes:
    buf = make_frame_header(version_index=6, direction_serverbound=True, steps=5)
    for i in range(5):
        append_stateless_frame(
            buf,
            state_selector=(2 + i) % 5,
            packet_id_selector=0x30 + i,
            packet_payload=payload_cookie_valid(),
            op_payload=op_payload_issue_1766(),
            op_index=10,
            codec_selector=0,
            codec_payload=b"",
            next_direction_serverbound=(i % 2 == 0),
            next_version_index=10 + i,
        )
    return bytes(buf)


def seed_issue_1742_decompression_attack() -> bytes:
    buf = make_frame_header(version_index=8, direction_serverbound=True, steps=4)
    for i in range(4):
        append_stateless_frame(
            buf,
            state_selector=(4 - i) % 5,
            packet_id_selector=0x20 + i,
            packet_payload=payload_cookie_valid(),
            op_payload=op_payload_issue_1742(),
            op_index=2,
            codec_selector=1,
            codec_payload=op_payload_issue_1742(),
            next_direction_serverbound=True,
            next_version_index=14 + i,
        )
    return bytes(buf)


def seed_issue_1768_nbt_heavy() -> bytes:
    buf = make_frame_header(version_index=12, direction_serverbound=True, steps=4)
    nbt_payload = op_payload_issue_1768()
    for i in range(4):
        append_stateless_frame(
            buf,
            state_selector=(1 + i) % 5,
            packet_id_selector=0x40 + i,
            packet_payload=payload_cookie_valid(),
            op_payload=nbt_payload,
            op_index=13 if i % 2 == 0 else 14,
            codec_selector=i % 3,
            codec_payload=nbt_payload,
            next_direction_serverbound=(i != 2),
            next_version_index=15 + i,
        )
    return bytes(buf)


def seed_deep_state_mixed() -> bytes:
    buf = make_frame_header(version_index=7, direction_serverbound=True, steps=12)
    for i in range(12):
        if i % 4 == 0:
            op_payload = op_payload_issue_1766()
            op_index = 10
            codec_selector = 2
            codec_payload = op_payload_issue_1766()
        elif i % 4 == 1:
            op_payload = op_payload_issue_1742()
            op_index = 2
            codec_selector = 1
            codec_payload = op_payload_issue_1742()
        elif i % 4 == 2:
            op_payload = op_payload_issue_1768()
            op_index = 13
            codec_selector = 0
            codec_payload = b""
        else:
            op_payload = repeat_pattern(b"F", 1024)
            op_index = 12
            codec_selector = 2
            codec_payload = repeat_pattern(b"F", 512)

        append_stateless_frame(
            buf,
            state_selector=i % 5,
            packet_id_selector=(0x10 + i) % 0x141,
            packet_payload=payload_cookie_valid() if i % 2 else payload_handshake_like(),
            op_payload=op_payload,
            op_index=op_index,
            codec_selector=codec_selector,
            codec_payload=codec_payload,
            next_direction_serverbound=(i % 3 != 1),
            next_version_index=(9 + i) % 35,
        )
    return bytes(buf)


def seed_status_handshake_baseline() -> bytes:
    buf = make_frame_header(version_index=1, direction_serverbound=True, steps=3)
    append_stateless_frame(
        buf,
        state_selector=0,
        packet_id_selector=0x00,
        packet_payload=payload_handshake_like(),
        op_payload=encode_varint(0x7FFFFFFF),
        op_index=0,
        codec_selector=0,
        codec_payload=b"",
        next_direction_serverbound=True,
        next_version_index=4,
    )
    append_stateless_frame(
        buf,
        state_selector=1,
        packet_id_selector=0x01,
        packet_payload=payload_status_ping_like(),
        op_payload=b"status-check",
        op_index=1,
        codec_selector=0,
        codec_payload=b"",
        next_direction_serverbound=False,
        next_version_index=8,
    )
    append_stateless_frame(
        buf,
        state_selector=2,
        packet_id_selector=0x02,
        packet_payload=payload_cookie_valid(),
        op_payload=b"brand-without-length",
        op_index=5,
        codec_selector=2,
        codec_payload=b"cookie-payload-123",
        next_direction_serverbound=True,
        next_version_index=10,
    )
    return bytes(buf)


RANDOM_TOKENS = (
    b"floodgate:skin",
    b"minecraft:brand",
    b"velocity:player_info",
    b"bungeecord:main",
    b"minecraft:stone",
    b"plugin-message-seed",
    b"decompression-attack-pattern",
    b"cookie-payload-123",
)


def inject_random_tokens(rng: random.Random, payload: bytearray) -> None:
    if not payload:
        return

    insertions = rng.randint(1, 6)
    for _ in range(insertions):
        token = rng.choice(RANDOM_TOKENS)
        if len(token) > len(payload):
            continue
        offset = rng.randint(0, len(payload) - len(token))
        payload[offset:offset + len(token)] = token


def seed_random_raw(rng: random.Random) -> bytes:
    size = rng.randint(1, 16384)
    payload = bytearray(rand_bytes(rng, size))

    if rng.random() < 0.3:
        fill = rng.choice((0x00, 0xFF, 0x7F, 0x80, 0x46))
        payload[:] = bytes([fill]) * size

    inject_random_tokens(rng, payload)
    return bytes(payload)


def seed_random_token_mix(rng: random.Random) -> bytes:
    size = rng.randint(96, 12288)
    payload = bytearray(rand_bytes(rng, size))
    inject_random_tokens(rng, payload)

    for _ in range(rng.randint(1, 4)):
        pos = rng.randint(0, len(payload))
        payload[pos:pos] = encode_varint(rng.randint(0, 8 * 1024 * 1024))

    return bytes(payload)


def seed_random_cursor_like(rng: random.Random) -> bytes:
    steps = rng.randint(1, 12)
    buf = bytearray()
    buf.extend(pack_i32(rng.getrandbits(32)))
    buf.append(rng.getrandbits(8))
    buf.extend(pack_i32(steps - 1))

    for _ in range(steps):
        buf.extend(pack_i32(rng.randint(0, 4)))  # stateless state selector
        buf.extend(pack_i32(rng.randint(0, 0x140)))  # packet id selector

        packet_len = rng.randint(0, 2048)
        buf.extend(pack_i32(packet_len))
        packet_payload = bytearray(rand_bytes(rng, packet_len))
        inject_random_tokens(rng, packet_payload)
        buf.extend(packet_payload)

        op_len = rng.randint(0, 1024)
        buf.extend(pack_i32(op_len))
        buf.extend(rand_bytes(rng, op_len))
        buf.extend(pack_i32(rng.randint(0, 16)))

        buf.extend(pack_i32(rng.randint(0, 2)))  # codec selector
        extra_len = rng.randint(0, 1024)
        buf.extend(pack_i32(extra_len))
        extra_payload = bytearray(rand_bytes(rng, extra_len))
        inject_random_tokens(rng, extra_payload)
        buf.extend(extra_payload)

        buf.append(rng.getrandbits(8))  # next direction
        buf.extend(pack_i32(rng.getrandbits(32)))  # next version selector

    return bytes(buf)


def random_seed_inputs(count: int, prng_seed: int) -> dict[str, bytes]:
    rng = random.Random(prng_seed)
    seeds: dict[str, bytes] = {}

    for i in range(count):
        variant = i % 3
        if variant == 0:
            name = f"random-raw-{i:02d}"
            payload = seed_random_raw(rng)
        elif variant == 1:
            name = f"random-token-mix-{i:02d}"
            payload = seed_random_token_mix(rng)
        else:
            name = f"random-cursor-like-{i:02d}"
            payload = seed_random_cursor_like(rng)
        seeds[name] = payload

    return seeds


def write_seed(corpus_dir: Path, name: str, payload: bytes) -> None:
    digest = hashlib.sha1(payload).hexdigest()
    (corpus_dir / f"{name}-{digest[:12]}").write_bytes(payload)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    corpus_dir = root / "build" / "jazzer-stateless" / "corpus"
    corpus_dir.mkdir(parents=True, exist_ok=True)

    random_count = env_int("JAZZER_RANDOM_SEED_COUNT", 18, minimum=0)
    random_seed = env_int("JAZZER_RANDOM_PRNG_SEED", 20260420)

    seeds = {
        "issue-1770-plugin-message": seed_issue_1770_plugin_message(),
        "issue-1766-plugin-join-window": seed_issue_1766_plugin_join_window(),
        "issue-1742-decompression": seed_issue_1742_decompression_attack(),
        "issue-1768-nbt-heavy": seed_issue_1768_nbt_heavy(),
        "deep-state-mixed": seed_deep_state_mixed(),
        "status-handshake-baseline": seed_status_handshake_baseline(),
    }

    seeds.update(random_seed_inputs(random_count, random_seed))

    for name, payload in seeds.items():
        write_seed(corpus_dir, name, payload)


if __name__ == "__main__":
    main()
