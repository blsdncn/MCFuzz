#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/aflnet" "$TMP/repo/afl-mc-agent" "$TMP/repo/velocity" \
  "$TMP/repo/prismarinejs/node-minecraft-protocol" \
  "$TMP/repo/prismarinejs/flying-squid" \
  "$TMP/bin"

cat >"$TMP/repo/afl-mc-agent/gradlew" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "afl-mc-agent $*" >>"$PRIME_TEST_LOG"
if [[ " $* " == *" --offline " ]]; then
  exit 23
fi
if [[ "${PRIME_TEST_GRADLE_ONLINE_FAIL:-0}" == "1" ]]; then
  exit 25
fi
mkdir -p build/libs
touch build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar
SH
chmod +x "$TMP/repo/afl-mc-agent/gradlew"

cat >"$TMP/repo/velocity/gradlew" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "velocity $*" >>"$PRIME_TEST_LOG"
if [[ " $* " == *" --offline " ]]; then
  exit 23
fi
if [[ "${PRIME_TEST_GRADLE_ONLINE_FAIL:-0}" == "1" ]]; then
  exit 25
fi
mkdir -p proxy/build/libs
touch proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar
SH
chmod +x "$TMP/repo/velocity/gradlew"

cat >"$TMP/bin/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "npm $(pwd) $*" >>"$PRIME_TEST_LOG"
if [[ "${PRIME_TEST_NPM_FAIL:-0}" == "1" ]]; then
  exit 24
fi
mkdir -p node_modules
SH
chmod +x "$TMP/bin/npm"

cat >"$TMP/bin/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "make $(pwd) $*" >>"$PRIME_TEST_LOG"
if [[ "$(pwd)" == *"aflnet" ]]; then
  touch afl-fuzz aflnet-replay
fi
if [[ "$(pwd)" == *"afl-mc-agent" ]]; then
  touch libaflmcshm.so
fi
SH
chmod +x "$TMP/bin/make"

printf '{"name":"node-minecraft-protocol-fixture"}\n' >"$TMP/repo/prismarinejs/node-minecraft-protocol/package.json"
printf '{"name":"flying-squid-fixture"}\n' >"$TMP/repo/prismarinejs/flying-squid/package.json"
: >"$TMP/actions.log"

PRIME_TEST_LOG="$TMP/actions.log" \
PATH="$TMP/bin:$PATH" \
PRIME_ROOT="$TMP/repo" \
"$ROOT/scripts/prime-container-deps.sh" >"$TMP/prime.out" 2>"$TMP/prime.err"

# Gradle projects try offline/local first, then fall back to online when offline cannot satisfy deps.
grep -q 'afl-mc-agent .*--offline' "$TMP/actions.log" || { echo "missing afl-mc-agent offline attempt" >&2; cat "$TMP/actions.log" >&2; exit 1; }
grep -q 'velocity .*--offline' "$TMP/actions.log" || { echo "missing velocity offline attempt" >&2; cat "$TMP/actions.log" >&2; exit 1; }
grep -q '^afl-mc-agent .*shadowJar' "$TMP/actions.log" || { echo "missing afl-mc-agent online fallback" >&2; cat "$TMP/actions.log" >&2; exit 1; }
grep -q '^velocity .*:velocity-proxy:shadowJar' "$TMP/actions.log" || { echo "missing velocity online fallback" >&2; cat "$TMP/actions.log" >&2; exit 1; }

# Missing npm deps are installed from the network-capable path.
grep -q 'npm .*/prismarinejs/node-minecraft-protocol install' "$TMP/actions.log" || { echo "missing node-minecraft-protocol npm install" >&2; cat "$TMP/actions.log" >&2; exit 1; }
grep -q 'npm .*/prismarinejs/flying-squid install' "$TMP/actions.log" || { echo "missing flying-squid npm install" >&2; cat "$TMP/actions.log" >&2; exit 1; }

grep -q '^prime_status=PASS$' "$TMP/prime.out" || { echo "missing PASS status" >&2; cat "$TMP/prime.out" >&2; cat "$TMP/prime.err" >&2; exit 1; }

rm -rf "$TMP/repo/prismarinejs/node-minecraft-protocol/node_modules" \
  "$TMP/repo/prismarinejs/flying-squid/node_modules"
set +e
PRIME_TEST_LOG="$TMP/actions.log" \
PRIME_TEST_GRADLE_ONLINE_FAIL=1 \
PRIME_TEST_NPM_FAIL=1 \
PATH="$TMP/bin:$PATH" \
PRIME_ROOT="$TMP/repo" \
"$ROOT/scripts/prime-container-deps.sh" >"$TMP/prime-fail.out" 2>"$TMP/prime-fail.err"
fail_status=$?
set -e
[[ "$fail_status" -ne 0 ]] || { echo "prime unexpectedly passed when local and internet paths failed" >&2; cat "$TMP/prime-fail.out" >&2; exit 1; }
grep -q '^prime_status=FAIL$' "$TMP/prime-fail.out" || { echo "missing FAIL status" >&2; cat "$TMP/prime-fail.out" >&2; cat "$TMP/prime-fail.err" >&2; exit 1; }

echo "PASS: prime container deps local-first fallback"
