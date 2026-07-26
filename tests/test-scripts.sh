#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1" expected="$2"
  grep -Fq "$expected" "$file" || fail "$file does not contain: $expected"
}

test_ensure_up_uses_its_checkout_and_configured_docker() {
  local fixture_repo="$TMP_DIR/checkout with spaces"
  local fake_bin="$TMP_DIR/bin"
  local log="$TMP_DIR/docker.log"

  [[ -x "$REPO_DIR/scripts/ensure-up.sh" ]] || fail "scripts/ensure-up.sh is missing or not executable"

  mkdir -p "$fixture_repo/scripts" "$fake_bin"
  cp "$REPO_DIR/scripts/ensure-up.sh" "$fixture_repo/scripts/ensure-up.sh"

  cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "$PWD" >>"$TEST_LOG"
if [[ "${1:-}" == "info" ]]; then
  exit 0
fi
[[ "$*" == "compose up -d" ]]
EOF
  chmod +x "$fake_bin/docker"

  TEST_LOG="$log" DOCKER_BIN="$fake_bin/docker" \
    bash "$fixture_repo/scripts/ensure-up.sh"

  assert_file_contains "$log" "info|$fixture_repo"
  assert_file_contains "$log" "compose up -d|$fixture_repo"
}

test_launchd_installer_renders_portable_templates() {
  local fixture_repo="$TMP_DIR/public checkout"
  local agents_dir="$TMP_DIR/LaunchAgents"
  local backup_plist="$agents_dir/dev.graphiti.neo4j.backup.plist"
  local ensure_plist="$agents_dir/dev.graphiti.neo4j.ensure-up.plist"

  [[ -x "$REPO_DIR/scripts/install-launchd.sh" ]] || fail "scripts/install-launchd.sh is missing or not executable"
  [[ -d "$REPO_DIR/scripts/launchd" ]] || fail "scripts/launchd is missing"

  mkdir -p "$fixture_repo/scripts"
  cp "$REPO_DIR/scripts/install-launchd.sh" "$fixture_repo/scripts/install-launchd.sh"
  cp "$REPO_DIR/scripts/backup.sh" "$fixture_repo/scripts/backup.sh"
  cp "$REPO_DIR/scripts/ensure-up.sh" "$fixture_repo/scripts/ensure-up.sh"
  cp -R "$REPO_DIR/scripts/launchd" "$fixture_repo/scripts/launchd"

  LAUNCH_AGENTS_DIR="$agents_dir" bash "$fixture_repo/scripts/install-launchd.sh"

  [[ -f "$backup_plist" ]] || fail "backup LaunchAgent was not rendered"
  [[ -f "$ensure_plist" ]] || fail "ensure-up LaunchAgent was not rendered"
  [[ -d "$fixture_repo/backups" ]] || fail "installer did not create the launchd log directory"
  assert_file_contains "$backup_plist" "$fixture_repo/scripts/backup.sh"
  assert_file_contains "$backup_plist" "$fixture_repo/scripts/ensure-up.sh"
  assert_file_contains "$ensure_plist" "$fixture_repo/scripts/ensure-up.sh"

  if grep -R -E '__[A-Z_]+__|/Users/|com\.alex' "$agents_dir"; then
    fail "rendered LaunchAgents contain unresolved or personal values"
  fi

  if LAUNCH_AGENTS_DIR="$agents_dir" bash "$fixture_repo/scripts/install-launchd.sh" >/dev/null 2>&1; then
    fail "installer overwrote existing LaunchAgents without --force"
  fi

  LAUNCH_AGENTS_DIR="$agents_dir" bash "$fixture_repo/scripts/install-launchd.sh" --force >/dev/null
}

test_backup_does_not_put_password_in_docker_arguments() {
  local fixture_repo="$TMP_DIR/backup checkout"
  local docker_log="$TMP_DIR/backup-docker.log"
  local bash_env="$TMP_DIR/fake-docker.sh"
  local secret="test-only-secret-value"

  mkdir -p "$fixture_repo/scripts" "$fixture_repo/backups"
  cp "$REPO_DIR/scripts/backup.sh" "$fixture_repo/scripts/backup.sh"
  printf 'NEO4J_PASSWORD=%s\n' "$secret" >"$fixture_repo/.env"

  cat >"$bash_env" <<'EOF'
docker() {
  printf '%s\n' "$*" >>"$TEST_LOG"
  case "${1:-}" in
    ps)
      printf 'neo4j-graphiti\n'
      ;;
    run)
      : >"$TEST_BACKUP_DIR/neo4j.dump"
      ;;
    exec)
      printf 'currentStatus\n"online"\n'
      ;;
  esac
  return 0
}
export -f docker
EOF

  BASH_ENV="$bash_env" TEST_LOG="$docker_log" TEST_BACKUP_DIR="$fixture_repo/backups" \
    bash "$fixture_repo/scripts/backup.sh" >/dev/null

  if grep -Fq "$secret" "$docker_log"; then
    fail "backup script exposed NEO4J_PASSWORD in Docker arguments"
  fi
  assert_file_contains "$docker_log" "exec --env-file $fixture_repo/.env -e NEO4J_USERNAME=neo4j"
}

test_ensure_up_uses_its_checkout_and_configured_docker
test_launchd_installer_renders_portable_templates
test_backup_does_not_put_password_in_docker_arguments

echo "PASS: script behavior"
