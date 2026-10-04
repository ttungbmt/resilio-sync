# Sync listening port is 44555, owned by `.env` and pushed into `sync.conf` at start

Sync advertises its `listening_port` to peers, so the published host port must equal it, and the two used to be kept in step by hand (`SYNC_PORT` in `.env`, `listening_port` in `sync.conf`). Sync's default `55555` failed on this WSL2 host because Hyper-V/WinNAT reserves random ranges in `49152-65535` that change across reboots, so we use `44555`, which is below that range. To remove the manual step, `SYNC_PORT` is the single source of truth: `init/10-listening-port.sh` (linuxserver's `/custom-cont-init.d` hook) rewrites `listening_port` on every container start.

## Consequences

- Changing the port in the web UI (Preferences → Advanced) is undone on the next restart; change `SYNC_PORT` instead.
- Remote peers' firewall or router forwards must be updated whenever `SYNC_PORT` changes.
- `init/` must be owned by root on the host, because linuxserver runs those scripts as root.
