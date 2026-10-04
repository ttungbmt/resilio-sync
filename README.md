# Resilio Sync

Self-hosted [Resilio Sync](https://www.resilio.com/sync/) on Docker Compose, using the [linuxserver.io image](https://docs.linuxserver.io/images/docker-resilio-sync/). Background, licensing and troubleshooting: [`docs/research/resilio-sync-docker.md`](docs/research/resilio-sync-docker.md).

## Quick start

```bash
cp .env.example .env               # set PUID/PGID (`id -u` / `id -g`), TZ
mkdir -p data/config data/sync data/downloads
sudo chown -R root:root init       # linuxserver only trusts root-owned init scripts
docker compose config -q && docker compose up -d
```

Open the web UI at <http://127.0.0.1:8888/gui/>. It only listens on loopback, so from another machine use `ssh -L 8888:127.0.0.1:8888 <host>`.

Forward `SYNC_PORT` (default `44555`) over **TCP and UDP** on your firewall or router if you have peers outside the LAN.

## Layout

| Path | Purpose |
|---|---|
| `compose.yaml`, `.env.example` | The stack and its settings (copy to `.env`) |
| `compose.override.example.yaml` | Template for per-machine mounts (e.g. Obsidian vaults) under `/sync/vaults/<name>`. Copy to `compose.override.yaml` |
| `init/10-listening-port.sh` | Runs at container start and sets Sync's `listening_port` to `SYNC_PORT` |
| `scripts/sync-latency.sh` | Measures how long changes take to propagate between two linked folders: `scripts/sync-latency.sh <dir-A> <dir-B> [timeout]` |
| `data/` | Runtime state and synced folders (gitignored) |
