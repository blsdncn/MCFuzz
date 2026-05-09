#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

run_gradle_local_then_online() {
  local name="$1"
  local dir="$2"
  shift 2
  local -a tasks=("$@")

  [[ -x "$dir/gradlew" ]] || { echo "${name}_status=FAIL reason=missing-gradlew:$dir/gradlew" >&2; exit 2; }

  echo "[$name] gradle --offline ${tasks[*]}"
  if (cd "$dir" && ./gradlew --offline "${tasks[@]}" --no-daemon); then
    echo "${name}_status=PASS"
    echo "${name}_dependency_mode=local"
    return 0
  fi

  echo "[$name] offline resolution failed; trying online"
  if (cd "$dir" && ./gradlew "${tasks[@]}" --no-daemon); then
    echo "${name}_status=PASS"
    echo "${name}_dependency_mode=internet"
    return 0
  fi

  echo "${name}_status=FAIL reason=gradle-local-and-internet-failed" >&2
  exit 1
}

require_file() {
  local p="$1"
  [[ -f "$p" ]] || { echo "missing built artifact: $p" >&2; exit 1; }
}

echo "[aflnet] make"
make -C "$ROOT/aflnet"

echo "[afl-mc-agent] native make"
make -C "$ROOT/afl-mc-agent"

run_gradle_local_then_online "afl_mc_agent_shadowjar" "$ROOT/afl-mc-agent" shadowJar
run_gradle_local_then_online "velocity_proxy_shadowjar" "$ROOT/velocity" :velocity-proxy:shadowJar

ARCH="$(uname -m)"
require_file "$ROOT/velocity/native/src/main/resources/linux_$ARCH/velocity-compress.so"
if openssl version | awk '{print $2}' | grep -q '^3\.'; then
  require_file "$ROOT/velocity/native/src/main/resources/linux_$ARCH/velocity-cipher-ossl30x.so"
elif openssl version | awk '{print $2}' | grep -q '^1\.1\.'; then
  require_file "$ROOT/velocity/native/src/main/resources/linux_$ARCH/velocity-cipher-ossl11x.so"
fi
require_file "$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
require_file "$ROOT/velocity/proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar"
require_file "$ROOT/aflnet/afl-fuzz"

if [[ -d "$ROOT/velocity-jazzer-integration" ]]; then
  require_file "$ROOT/velocity-jazzer-integration/build/jazzer/tools/jazzer-0.24.0.jar"

  run_gradle_local_then_online "velocity_jazzer_test_classes" \
    "$ROOT/velocity-jazzer-integration" :velocity-proxy:testClasses
  require_file "$ROOT/velocity-jazzer-integration/proxy/build/classes/java/test/com/velocitypowered/proxy/fuzz/VelocityProtocolStateFuzzTarget.class"
  require_file "$ROOT/velocity-jazzer-integration/proxy/build/classes/java/test/com/velocitypowered/proxy/fuzz/VelocityProtocolStateless.class"

  echo "[jacoco] pre-stage agent + cli jars"
  "$ROOT/scripts/resolve-jacoco-outer-jar.sh" >/dev/null
  "$ROOT/scripts/resolve-jacoco-cli-jar.sh"   >/dev/null
fi

echo "required_artifacts_status=PASS"
