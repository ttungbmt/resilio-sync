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
5. Web UI: `curl -s -o /dev/null -w '%{http_code}\n' "http://$(docker compose port resilio-sync 8888)/gui/"` (the UI is plain HTTP). Expect 200/401/302.
6. Sync port: confirm `SYNC_PORT` (default 44555) is published for both TCP and UDP in `docker compose ps`, and that the logs contain `listening_port set to <port>` from `init/10-listening-port.sh`. A log box saying `/custom-cont-init.d` is "not owned by root" means `init/` needs `sudo chown -R root:root init`.

## Report

Summarize in a short table: check, result (ok/fail), detail. For any failure, give the likely cause and the concrete fix. Never run `docker compose down -v` or remove volumes.
