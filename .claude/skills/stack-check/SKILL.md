---
name: stack-check
description: Bring up the Resilio Sync Docker Compose stack and verify container health, logs, ports, and volume permissions
disable-model-invocation: true
---

# Stack check

Bring up the Resilio Sync stack and report whether it is healthy. Do not read or modify anything under `data/` or the `.env` file.

## Steps

1. Validate config: `docker compose config -q`. Stop and report if it fails.
2. Start: `docker compose up -d`.
3. Status: `docker compose ps`. Every service should be `running` (and `healthy` if a healthcheck is defined). If a service is restarting, wait a few seconds and check again once.
4. Logs: `docker compose logs --tail=50`. Look for errors, especially:
   - permission denied on `/sync`, `/mnt/...` or config paths → PUID/PGID mismatch with host ownership
   - port already in use
   - license / storage path errors
5. Web UI: `curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8888/gui/` (adjust the port if compose maps it differently). Expect 200/401/302.
6. Sync port: confirm the listening port (default 55555 TCP/UDP) is published in `docker compose ps` output.

## Report

Summarize in a short table: check, result (ok/fail), detail. For any failure, give the likely cause and the concrete fix. Never run `docker compose down -v` or remove volumes.
