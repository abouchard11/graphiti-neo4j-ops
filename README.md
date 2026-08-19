# Graphiti Neo4j Ops

[![Validate](https://github.com/abouchard11/graphiti-neo4j-ops/actions/workflows/validate.yml/badge.svg)](https://github.com/abouchard11/graphiti-neo4j-ops/actions/workflows/validate.yml)
[![Release](https://img.shields.io/github/v/release/abouchard11/graphiti-neo4j-ops)](https://github.com/abouchard11/graphiti-neo4j-ops/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A production-minded local Neo4j runtime for
[Graphiti](https://github.com/getzep/graphiti): loopback-only networking,
health-driven recovery, safe Community Edition backups, and optional macOS
startup automation.

This repository operates the database Graphiti connects to. It does not fork or
bundle Graphiti itself.

## What it adds

- Neo4j 5.26 with APOC and persistent named volumes
- HTTP and Bolt bound to `127.0.0.1` only
- a real database healthcheck, not just a process check
- an isolated, pinned autoheal sidecar for unhealthy-container recovery
- a 120-second graceful stop window to avoid stale store locks
- offline Community Edition dumps with restart verification and self-healing
- one-backup-per-day catch-up behavior after a sleeping or powered-off Mac
- portable macOS LaunchAgent templates generated for the current checkout
- CI validation for shell scripts, Compose configuration, and plist XML

## Requirements

- Docker Engine or Docker Desktop with Compose v2
- 4-6 GB of memory available to Docker for the default tuning
- macOS only if you want the optional LaunchAgents

## Quick start

```bash
cp .env.example .env
# Replace the placeholder password in .env.
docker compose up -d
docker compose ps
```

Verify the database itself is online:

```bash
docker exec neo4j-graphiti cypher-shell \
  -u neo4j \
  -p "$(sed -n 's/^NEO4J_PASSWORD=//p' .env)" \
  'RETURN 1'
```

Connect Graphiti to `bolt://localhost:7687` with username `neo4j` and the
password stored in your local `.env`. The file is ignored by Git.

## Ports and remote access

| Port | Purpose |
| --- | --- |
| `7474` | Neo4j Browser / HTTP |
| `7687` | Bolt driver protocol |

Both are loopback-only. For remote administration, use an SSH tunnel rather
than exposing Neo4j directly:

```bash
ssh -L 7687:localhost:7687 user@host
```

## Backups

Neo4j Community Edition requires the database to be offline for a consistent
dump. `scripts/backup.sh` therefore:

1. stops the Neo4j container gracefully;
2. dumps the store from a throwaway container;
3. restarts Neo4j and verifies the `neo4j` database is online;
4. retries with a container restart if recovery is needed;
5. retains seven days of nightly dumps by default.

Run it manually:

```bash
bash scripts/backup.sh
```

The script skips when a `nightly-YYYYMMDD-*.dump` already exists, making it safe
to run at login as a catch-up job. Dumps and logs are written under `backups/`,
which is ignored by Git.

### Restore

Restoring destroys the current graph. Take another backup first.

```bash
docker compose down
cp backups/nightly-YYYYMMDD-HHMMSS.dump backups/neo4j.dump
docker run --rm \
  -v neo4j_graphiti_data:/data \
  -v "$PWD/backups:/backups" \
  neo4j:5.26.0 \
  neo4j-admin database load neo4j \
    --from-path=/backups \
    --overwrite-destination
docker compose up -d
```

## macOS automation

Render LaunchAgents using the current checkout path:

```bash
bash scripts/install-launchd.sh
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.graphiti.neo4j.backup.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.graphiti.neo4j.ensure-up.plist"
```

The backup agent runs at 03:15 and at login, with the daily guard preventing
duplicates. The ensure-up agent waits for Docker Desktop, then runs
`docker compose up -d`. Re-render existing files with
`bash scripts/install-launchd.sh --force`.

## Security model

- Neo4j is not exposed beyond the host.
- Passwords belong only in `.env`; never commit that file.
- The autoheal container has no network, a read-only filesystem, and a pinned
  image, but Docker socket access is still highly privileged. Only run trusted
  images with socket access.
- The named data volume is persistent. `docker compose down -v` deletes data;
  do not run it without a verified backup.

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Validation

```bash
bash tests/test-scripts.sh
docker compose --env-file .env.example config --quiet
xmllint --noout scripts/launchd/*.plist.template
```

CI also runs ShellCheck across every shell script.

## License

MIT

## Related

This repo is the **entity-store ops** lane. Agent memory that lands here is supposed to be a verified increment, not a chat dump.

- [llm-safety-gate](https://github.com/abouchard11/llm-safety-gate) — fail-closed discipline at the classifier layer
- [yapoleons-court](https://github.com/abouchard11/yapoleons-court) — shipped product where the model cannot own the score
- Upstream: [getzep/graphiti](https://github.com/getzep/graphiti)
