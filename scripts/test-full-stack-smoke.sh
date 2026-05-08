#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-$ROOT/seeds/play-chat.bin}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

"$ROOT/scripts/run-stack-smoke.sh" "$SEED" >"$OUT" 2>&1

grep -q "\[run-stack-smoke\] Temporary instrumentation exclusion active: com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket" "$OUT"
grep -q "\[afl-mc-agent\] Exclude patterns: com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket" "$OUT"
grep -q "PASS: full stack smoke" "$OUT"
