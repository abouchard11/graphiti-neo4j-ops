#!/usr/bin/env bash
# Nightly backup for neo4j-graphiti (Neo4j 5.26 COMMUNITY).
#
# Community Edition can only dump an OFFLINE database, so the DBMS must be down
# for the dump. The previous approach stopped neo4j *inside* the container
# (`neo4j stop` / `neo4j start`), but that proved unreliable on the official
# image: `neo4j stop` often returns non-zero and the in-process restart
# intermittently leaves a stale /data/databases/neo4j/database_lock
# (FileLockException), wedging the 'neo4j' database (DatabaseUnavailable) while
# bolt/system/the container stay "Up". Container-level stop/start was proven
# reliable, so this script now:
#   1. `docker stop -t 120` the container  (graceful: JVM checkpoints + releases
#      the store lock cleanly; overrides the container's short StopTimeout)
#   2. dumps from a throwaway neo4j container mounting the same data volume
#      (the main DBMS is offline, so the dump acquires the lock without a race)
#   3. `docker start` the container and VERIFIES the 'neo4j' database is online
#   4. self-heals via `docker restart` as a belt-and-suspenders fallback, and
#      the willfarrell/autoheal sidecar is an independent backstop
#
# Optional LaunchAgent templates live in scripts/launchd/.
# Manual run: bash scripts/backup.sh
#
# Exit codes:
#   0 success (dump taken AND 'neo4j' database verified online)
#   1 container not running / password unreadable
#   2 dump failed
#   4 'neo4j' database did not return online after start + self-heal (INVESTIGATE)

set -euo pipefail

CONTAINER="neo4j-graphiti"
IMAGE="neo4j:5.26.0"            # must match docker-compose.yml (same store format)
DATA_VOLUME="neo4j_graphiti_data"  # external volume mounted at /data in compose
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$REPO_DIR/backups"
LOG_FILE="${BACKUP_DIR}/backup.log"
TS="$(date +%Y%m%d-%H%M%S)"
KEEP_DAYS=7

# Neo4j password is read by Docker from an env file at runtime, never copied
# into this process's command arguments. Defaults to the same repo-local .env
# that Compose uses. Override with NEO4J_GRAPHITI_ENV_FILE=/path/to/.env.
ENV_FILE="${NEO4J_GRAPHITI_ENV_FILE:-$REPO_DIR/.env}"

# Ensure docker is on PATH (launchd starts with a minimal env)
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

mkdir -p "$BACKUP_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [[ ! -r "$ENV_FILE" ]] || ! grep -q '^NEO4J_PASSWORD=.' "$ENV_FILE"; then
  log "ERROR: could not read NEO4J_PASSWORD from $ENV_FILE"
  exit 1
fi

# Poll until the 'neo4j' database reports currentStatus=online. The DBMS reports
# this via SHOW DATABASE once it has (re)acquired the store lock. Returns 0 if the
# database reaches 'online' within $1 seconds, else 1.
wait_for_neo4j_online() {
  local timeout="${1:-90}" waited=0 status
  while (( waited < timeout )); do
    status="$(docker exec --env-file "$ENV_FILE" -e NEO4J_USERNAME=neo4j "$CONTAINER" \
      cypher-shell -d system --format plain \
      "SHOW DATABASE neo4j YIELD currentStatus RETURN currentStatus" 2>/dev/null \
      | tail -1 | tr -d '"' || true)"
    if [[ "$status" == "online" ]]; then
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  return 1
}

log "=== backup start ts=$TS ==="

# Idempotency / catch-up guard: skip if a dump already exists for today. This
# makes the script safe to run repeatedly, which is what lets RunAtLoad=true in
# the plist act as a catch-up: StartCalendarInterval only re-fires after SLEEP,
# not after a power-OFF, so a night the Mac was shut down at 03:15 was silently
# skipped (e.g. 2026-07-08). With RunAtLoad the job also runs at the next login;
# this guard makes that a no-op on days already backed up, and a real catch-up
# backup on days that were missed. At most one nightly dump per calendar day.
TODAY="$(date +%Y%m%d)"
if compgen -G "$BACKUP_DIR/nightly-${TODAY}-*.dump" >/dev/null 2>&1; then
  log "skip: a nightly dump for ${TODAY} already exists — nothing to do"
  exit 0
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  log "ERROR: container $CONTAINER not running"
  exit 1
fi

# 1. Graceful container stop — lets the JVM checkpoint and release the store lock
#    cleanly. `-t 120` overrides the container's short StopTimeout. An explicit
#    `docker stop` does NOT trip restart:unless-stopped (only crashes do).
log "stopping container (graceful, -t 120)..."
docker stop -t 120 "$CONTAINER" >>"$LOG_FILE" 2>&1

# 2. Dump from a throwaway container against the now-offline data volume. Nothing
#    else holds the store lock, so there is no restart-vs-dump race.
log "dumping (offline, throwaway $IMAGE container)..."
rm -f "$BACKUP_DIR/neo4j.dump"
if ! docker run --rm \
      -v "$DATA_VOLUME":/data \
      -v "$BACKUP_DIR":/out \
      "$IMAGE" \
      neo4j-admin database dump neo4j --to-path=/out >>"$LOG_FILE" 2>&1; then
  log "ERROR: dump failed — restarting container and bailing"
  docker start "$CONTAINER" >>"$LOG_FILE" 2>&1 || true
  exit 2
fi
mv "$BACKUP_DIR/neo4j.dump" "$BACKUP_DIR/nightly-$TS.dump"

# 3. Bring the DBMS back up and VERIFY the 'neo4j' database actually comes online.
log "starting container..."
docker start "$CONTAINER" >>"$LOG_FILE" 2>&1

if wait_for_neo4j_online 90; then
  log "verified: 'neo4j' database is online"
else
  # Belt-and-suspenders: should be rare now that the dump no longer races a
  # restart, but a stale lock from any cause is cleared by a full restart.
  log "WARN: 'neo4j' database not online after start — self-healing via 'docker restart $CONTAINER'"
  if ! docker restart "$CONTAINER" >>"$LOG_FILE" 2>&1; then
    log "ERROR: 'docker restart $CONTAINER' failed during self-heal — manual intervention required"
    exit 4
  fi
  if wait_for_neo4j_online 120; then
    log "recovered: 'neo4j' database online after container restart"
  else
    log "ERROR: 'neo4j' database STILL not online after self-heal — manual intervention required"
    log "       recovery: docker restart $CONTAINER ; then: docker logs $CONTAINER"
    exit 4
  fi
fi

# 4. Prune old dumps.
DEST="$BACKUP_DIR/nightly-$TS.dump"
log "pruning nightly dumps older than ${KEEP_DAYS}d..."
find "$BACKUP_DIR" -maxdepth 1 -name 'nightly-*.dump' -type f -mtime +${KEEP_DAYS} -print -delete >>"$LOG_FILE" 2>&1 || true

SIZE="$(du -h "$DEST" | cut -f1)"
log "OK: $DEST ($SIZE)"
log "=== backup end ==="
