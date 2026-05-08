#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CACHE_JAR="$TMP/gradle-home/caches/modules-2/files-2.1/org.jacoco/org.jacoco.agent/0.8.14/hash/org.jacoco.agent-0.8.14.jar"
mkdir -p "$(dirname "$CACHE_JAR")" "$TMP/bin"
printf 'cache-jar\n' >"$CACHE_JAR"

CURL_LOG="$TMP/curl.log"
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CURL_LOG:?}"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'downloaded-jar\n' >"$out"
SH
chmod +x "$TMP/bin/curl"

resolved="$(GRADLE_USER_HOME="$TMP/gradle-home" PATH="$TMP/bin:$PATH" "$ROOT/scripts/resolve-jacoco-outer-jar.sh")"
[[ "$resolved" == "$CACHE_JAR" ]] || { echo "expected cached path, got $resolved" >&2; exit 1; }
[[ ! -f "$CURL_LOG" ]] || { echo "curl should not run when cache hit exists" >&2; exit 1; }

rm -rf "$TMP/gradle-home/caches"
resolved="$(GRADLE_USER_HOME="$TMP/gradle-home" CURL_LOG="$CURL_LOG" PATH="$TMP/bin:$PATH" "$ROOT/scripts/resolve-jacoco-outer-jar.sh")"
[[ -f "$resolved" ]] || { echo "downloaded jar missing: $resolved" >&2; exit 1; }
grep -q 'repo1.maven.org' "$CURL_LOG" || { echo "expected curl download log" >&2; cat "$CURL_LOG" >&2; exit 1; }

echo "PASS: resolve JaCoCo outer jar local-first fallback"
