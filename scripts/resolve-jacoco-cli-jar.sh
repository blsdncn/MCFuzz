#!/usr/bin/env bash
set -euo pipefail

VERSION="${JACOCO_VERSION:-0.8.14}"
EXPLICIT_PATH="${1:-${JACOCO_CLI_JAR:-}}"
GRADLE_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
CACHE_ROOT="$GRADLE_HOME/caches/modules-2/files-2.1/org.jacoco/org.jacoco.cli"
DOWNLOAD_DIR="${JACOCO_DOWNLOAD_DIR:-$GRADLE_HOME/downloads/org.jacoco.cli/$VERSION}"
DOWNLOAD_PATH="$DOWNLOAD_DIR/org.jacoco.cli-$VERSION-nodeps.jar"
DOWNLOAD_URL="${JACOCO_CLI_URL:-https://repo1.maven.org/maven2/org/jacoco/org.jacoco.cli/$VERSION/org.jacoco.cli-$VERSION-nodeps.jar}"

if [[ -n "$EXPLICIT_PATH" ]]; then
  [[ -f "$EXPLICIT_PATH" ]] || { echo "Missing explicit JaCoCo CLI jar: $EXPLICIT_PATH" >&2; exit 2; }
  echo "$EXPLICIT_PATH"
  exit 0
fi

cached_path="$(find "$CACHE_ROOT" -path "*/$VERSION/*/org.jacoco.cli-$VERSION-nodeps.jar" -print -quit 2>/dev/null || true)"
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
  echo "Could not resolve JaCoCo CLI jar locally and neither curl nor wget is available" >&2
  exit 1
fi

[[ -s "$DOWNLOAD_PATH" ]] || { echo "Downloaded JaCoCo CLI jar is empty: $DOWNLOAD_PATH" >&2; exit 1; }
echo "$DOWNLOAD_PATH"
