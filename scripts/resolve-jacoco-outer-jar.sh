#!/usr/bin/env bash
set -euo pipefail

VERSION="${JACOCO_VERSION:-0.8.14}"
EXPLICIT_PATH="${1:-${JACOCO_AGENT_OUTER_JAR:-}}"
GRADLE_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
CACHE_ROOT="$GRADLE_HOME/caches/modules-2/files-2.1/org.jacoco/org.jacoco.agent"
DOWNLOAD_DIR="${JACOCO_DOWNLOAD_DIR:-$GRADLE_HOME/downloads/org.jacoco/org.jacoco.agent/$VERSION}"
DOWNLOAD_PATH="$DOWNLOAD_DIR/org.jacoco.agent-$VERSION.jar"
DOWNLOAD_URL="${JACOCO_AGENT_URL:-https://repo1.maven.org/maven2/org/jacoco/org.jacoco.agent/$VERSION/org.jacoco.agent-$VERSION.jar}"

if [[ -n "$EXPLICIT_PATH" ]]; then
  [[ -f "$EXPLICIT_PATH" ]] || { echo "Missing explicit JaCoCo outer jar: $EXPLICIT_PATH" >&2; exit 2; }
  echo "$EXPLICIT_PATH"
  exit 0
fi

cached_path="$(find "$CACHE_ROOT" -path "*/$VERSION/*/org.jacoco.agent-$VERSION.jar" -print -quit 2>/dev/null || true)"
if [[ -n "$cached_path" ]]; then
  echo "$cached_path"
  exit 0
fi

if [[ -s "$DOWNLOAD_PATH" ]]; then
  echo "$DOWNLOAD_PATH"
  exit 0
fi

mkdir -p "$DOWNLOAD_DIR"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$DOWNLOAD_URL" -o "$DOWNLOAD_PATH"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$DOWNLOAD_PATH" "$DOWNLOAD_URL"
else
  echo "Could not resolve JaCoCo outer jar locally and neither curl nor wget is available" >&2
  exit 1
fi

[[ -s "$DOWNLOAD_PATH" ]] || { echo "Downloaded JaCoCo outer jar is empty: $DOWNLOAD_PATH" >&2; exit 1; }
echo "$DOWNLOAD_PATH"
