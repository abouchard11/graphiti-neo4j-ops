#!/usr/bin/env bash
# Render portable LaunchAgent templates for this checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/launchd"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
FORCE=false

if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
  shift
fi

if (( $# > 0 )); then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

render_template() {
  local template="$1" target="$2" escaped_repo

  if [[ -e "$target" && "$FORCE" != true ]]; then
    echo "ERROR: $target already exists; rerun with --force to replace it" >&2
    return 1
  fi

  escaped_repo="$(escape_sed_replacement "$REPO_DIR")"
  sed "s|__REPO_DIR__|$escaped_repo|g" "$template" >"$target"
  chmod 600 "$target"
  echo "installed $target"
}

mkdir -p "$LAUNCH_AGENTS_DIR" "$REPO_DIR/backups"
render_template \
  "$TEMPLATE_DIR/dev.graphiti.neo4j.backup.plist.template" \
  "$LAUNCH_AGENTS_DIR/dev.graphiti.neo4j.backup.plist"
render_template \
  "$TEMPLATE_DIR/dev.graphiti.neo4j.ensure-up.plist.template" \
  "$LAUNCH_AGENTS_DIR/dev.graphiti.neo4j.ensure-up.plist"

echo "Load with: launchctl bootstrap gui/$(id -u) $LAUNCH_AGENTS_DIR/dev.graphiti.neo4j.backup.plist"
echo "Load with: launchctl bootstrap gui/$(id -u) $LAUNCH_AGENTS_DIR/dev.graphiti.neo4j.ensure-up.plist"
