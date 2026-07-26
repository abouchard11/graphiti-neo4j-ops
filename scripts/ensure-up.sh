#!/usr/bin/env bash
# Bring the compose stack up after Docker becomes available.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker || true)}"

if [[ -z "$DOCKER_BIN" ]]; then
  echo "ERROR: docker was not found" >&2
  exit 1
fi

cd "$COMPOSE_DIR"

for _ in $(seq 1 60); do
  if "$DOCKER_BIN" info >/dev/null 2>&1; then
    exec "$DOCKER_BIN" compose up -d
  fi
  sleep 5
done

echo "ERROR: Docker did not become available within five minutes" >&2
exit 1
