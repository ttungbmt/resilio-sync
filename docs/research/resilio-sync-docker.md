# Running Resilio Sync with Docker Compose

Research note and setup guide for this repo's self-hosted Resilio Sync stack.

- **Researched:** 2026-10-04
- **Scope:** official `resilio/sync` image vs. `lscr.io/linuxserver/resilio-sync`, ports, `sync.conf`, licensing, security, permissions, and a step-by-step Compose setup.
- **Source rules:** every claim cites a primary source (see [Sources](#sources)). Statements marked **(inference)** are my own reasoning, not something a source says. Statements marked **(unverified)** were not confirmed against a primary source.

---

## 1. TL;DR

| Topic | Finding |
|---|---|
| Recommended image | `lscr.io/linuxserver/resilio-sync`, pinned to a version tag (currently `3.1.2`, i.e. Sync `3.1.2.1076`, built 2026-09-29) [S7][S9] |
| Why not the official image | `resilio/sync` was last pushed 2024-06-03 (Sync 2.8.1, amd64 only) [S3][S4], and Resilio's Sync 3.0 change log lists Docker as a deprecated platform [S12] |
| Ports to publish | `8888/tcp` web UI (bind to `127.0.0.1`), `55555/tcp` and `55555/udp` listening port [S2][S10][S11] |
| Ports you don't publish | `3838/udp` LAN discovery is multicast/broadcast. A port mapping won't carry it through Docker's bridge network **(inference)** [S10] |
| Volumes (linuxserver) | `/config` (`sync.conf` and storage: identity, settings, DB), `/sync` (synced folders root), `/downloads` (default download path) [S7][S8] |
| Permissions | Set `PUID`/`PGID` to the host owner of `data/` (`id -u`, `id -g`) [S7][S13] |
| Licence (Sync 3.x) | Free for non-commercial use, but you need to register and apply a free licence key. Sync Business licences don't work on v3 [S14][S15][S16] |
| Biggest gotchas | linuxserver's own example publishes `55555` as TCP only, so add the UDP mapping. Docker-published ports bypass `ufw` [S7][S19]. On WSL2 in NAT mode, LAN peers can't reach the container without extra setup [S20] |

---

## 2. Image comparison: official vs. linuxserver.io

| | `resilio/sync` (official) | `lscr.io/linuxserver/resilio-sync` |
|---|---|---|
| Source repo | `github.com/bt-sync/sync-docker` [S2] | `github.com/linuxserver/docker-resilio-sync` [S8] |
| Latest tag / Sync version | `latest` = `2.8.1`, pushed 2024-06-03 [S4] | `latest` = `3.1.2` / `3.1.2.1076-1-ls261`, pushed 2026-09-29 [S9] |
| Repo activity | last commit 2024-06-03, not archived [S2] | last push 2026-09-29, not archived. Rebuilds are automated [S8] |
| Architectures | `amd64` only (Dockerfile downloads the `x64` tarball) [S3][S4] | `amd64`, `arm64` (armhf deprecated 2023-07-03) [S7][S9] |
| Base image | `ubuntu` (untagged) [S3] | `ghcr.io/linuxserver/baseimage-ubuntu:noble`. Installs `resilio-sync` from Resilio's official apt repo [S8] |
| Process manager | bash wrapper `run_sync` → `rslsync --nodaemon` [S3] | s6-overlay. Runs `rslsync` as user `abc` via `s6-setuidgid` [S8] |
| PUID/PGID | README says "use `--user` … or set `PUID` and `PGID`" [S2], **but the entrypoint `run_sync` never reads `PUID`/`PGID`**. Only `--user` / Compose `user:` actually works [S3] | Full support for `PUID`, `PGID`, `UMASK` and `TZ` [S7][S13] |
| Config path | single volume `/mnt/sync`: `sync.conf` at `/mnt/sync/sync.conf`, storage at `/mnt/sync/config`, folders at `/mnt/sync/folders`, extra mounts under `/mnt/mounted_folders` [S3] | `/config/sync.conf`, storage `/config`, `directory_root` `/sync/`, `files_default_path` `/downloads` [S8] |
| Default `sync.conf` | `webui.listen 0.0.0.0:8888`, `allow_empty_password: false`, `dir_whitelist [/mnt/sync/folders, /mnt/mounted_folders]` [S3] | `webui.listen 0.0.0.0:8888`, `allow_empty_password: false`, `dir_whitelist [/sync, /sync/folders, /sync/mounted_folders]` [S8] |
| Healthcheck | none | s6 readiness check `nc -z localhost 8888` (internal, not a Docker `HEALTHCHECK`) [S8] |

**Conflict:** the official README claims PUID/PGID support, but the `run_sync` script in the same repo ignores those variables [S2][S3]. Trust the code.

**Conflict:** Resilio's Sync 3.0 change log says "Deprecated support for … Docker" [S12], yet the official repo still exists and isn't archived [S2]. In practice the official image is frozen at 2.8.1.

**Recommendation:** use the linuxserver image. It's the only current, multi-arch image that tracks Resilio's official apt packages, and it handles host UID/GID mapping. linuxserver says this is why the image exists: "There is an official sync image but we created this one as it supports user mapping to simplify permissions for volumes." [S8 `readme-vars.yml`]

Note that linuxserver can only ship versions Resilio publishes to its apt repo, so image releases can lag Resilio's announcements [S17 (issue #52)].

---

## 3. Ports

Resilio's own port reference [S10] (article edited 2024-05-29):

| Port / protocol | Direction | Purpose | Publish from container? |
|---|---|---|---|
| `8888/tcp` | inbound | Web UI (default `webui.listen`) [S8][S11] | Yes, but bind to `127.0.0.1` (see §6) |
| `55555/tcp` + `55555/udp` | in + out | Sync's **listening port**. Peers connect to it directly over TCP and UDP. It "must be opened and forwarded on all firewalls, NATs and routers between the peers" [S10]. `55555` is the value in both images' default `sync.conf` [S3][S8] | **Yes, both protocols** |
| HTTPS/80 → `config.resilio.com` | outbound | Download the tracker/relay list [S10] | No (outbound only) |
| tracker (TCP+UDP) | outbound | Peer discovery over the Internet. Addresses come from `config.resilio.com/sync.conf` [S10] | No |
| relay (TCP) | outbound | Fallback when a direct connection fails [S10] | No |
| `3838/udp` multicast `239.192.0.0`, broadcast | LAN | LAN peer discovery [S10] | Not effective through the bridge network **(inference)** |
| `1900/udp` (UPnP, `239.255.255.250`), `5351/udp` (NAT-PMP to gateway) | outbound | Automatic router port mapping [S10] | No. Inside a bridge-networked container UPnP would map to the container IP, so forward the port on the router by hand instead **(inference)** |

### Notes

- **linuxserver's example maps TCP only.** Its compose sample has `- 55555:55555`, which Docker treats as TCP [S7]. Resilio needs TCP **and** UDP [S10], and the official repo publishes both `55555/tcp` and `55555/udp` [S2]. Add `55555:55555/udp`.
- **Keep host port == container port** for the listening port. Sync advertises its configured `listening_port` to the tracker, so a remapped host port (e.g. `9555:55555`) means peers dial the wrong port **(inference)**. To change it, change `listening_port` in `sync.conf` (or Preferences → Advanced → Listening port [S10]) and the Compose mapping together. The official README says the same: "you can change it, but in this case change it in Sync settings as well" [S2].
- **LAN discovery with bridge networking.** Multicast/broadcast discovery on `3838/udp` [S10] won't reach the container on the default bridge network **(inference)**. Peers still find each other through the tracker, which learns both public and local IPs [S10]. On a LAN with no Internet, or with the tracker disabled, either:
  - use `network_mode: host` (Linux hosts only; then you can't use `ports:`, and the web UI binds wherever `webui.listen` says, so set it to `127.0.0.1:8888`) **(inference)**, or
  - add **predefined hosts / known hosts** for each folder (`known_hosts` in config mode, or in folder preferences) [S11 (config mode)].

---

## 4. Configuration (`sync.conf`)

Both images start `rslsync --nodaemon --config <file>` [S3][S8], so Sync always runs in **configuration mode**.

### Command-line options (Linux) [S18]

`--config <file>`, `--storage <path>`, `--identity <name>` (headless identity creation), `--license <path>` (apply a licence headless), `--nodaemon`, `--dump-sample-config`, `--log <file>`, `--webui.listen <ip>:<port>`, `--generate-secret` (new read/write key), `--get-ro-secret <rw-key>`.

### Main keys [S11]

| Key | Meaning |
|---|---|
| `device_name`, `listening_port` | `0` = random port |
| `storage_path` | where Sync keeps settings, logs, identity, licence and share DB. In linuxserver this is `/config` [S8] |
| `pid_file` | defaults to storage folder |
| `use_upnp` | send UPnP / NAT-PMP mapping requests |
| `download_limit`, `upload_limit` | `0` = unlimited. By default limits apply only to Internet connections, not LAN |
| `directory_root`, `directory_root_policy` | `all` or `belowroot`. `belowroot` blocks creating folders directly in `directory_root` (both images use `belowroot`) [S3][S8] |
| `webui.listen` | e.g. `0.0.0.0:8888`. Remove it to disable the web UI |
| `webui.login`, `webui.password`, `webui.password_hash` (crypt(3)), `webui.password_hash_unified` + `webui.password_hash_salt_unified` | web UI credentials |
| `webui.allow_empty_password` | allow an empty password |
| `webui.force_https`, `webui.ssl_certificate`, `webui.ssl_private_key` | HTTPS for the web UI |
| `webui.dir_whitelist` | folders the web UI folder picker may use |
| `shared_folders[]` (`secret`, `dir`, `use_relay_server`, `search_lan`, `use_sync_trash`, `overwrite_changes`, `selective_sync`, `known_hosts`) | **Setting `shared_folders` disables the web UI**, and the folders override any added via the web UI. Config mode supports only "Standard" folders, not "Advanced" ones |

Advanced Preferences parameters can also go into the config file [S11].

### Things to know

- `sync.conf` is JSON, so validate it before restarting [S11].
- linuxserver copies `/defaults/sync.conf` to `/config/sync.conf` **only if it doesn't exist yet** [S8]. After that, the file in `data/config/` is yours to edit, and image updates won't overwrite it.
- **Web UI credentials:** you're asked to set them the first time you open the web UI [S18][S21]. You can also set them in `sync.conf`. Resilio's password-reset guide says that once the config credentials are accepted, "they will be stored in Sync settings" and the config entries can be removed [S22]. Prefer the first-run UI or `password_hash` over a plaintext `password` in a file **(inference)**.
- **Reset a lost web UI password:** stop Sync, delete `settings.dat` and `settings.dat.old` from the storage folder (`data/config/`), and restart. This duplicates the device in "My devices" and resets global preferences. Or set `webui.login`/`webui.password` in `sync.conf` [S22].
- **Adding a share by link** doesn't work by clicking a link with the web UI. Use **"+" → "Enter a key or link"** instead [S21][S18].
- **inotify limit:** large trees can exhaust `fs.inotify.max_user_watches` (default 8192), which leaves changes undetected until the periodic rescan. Raise it **on the host** with `sysctl`, since containers share the host kernel [S23][S17 (issue #47)].

---

## 5. Licensing (Sync 3.x, as of 2026-10)

- Sync 3.0.0.1409 shipped 2024-08-07. It made Pro features free for **non-commercial** use and deprecated Docker, Linux i386, ARMv7 and other platforms [S12]. Latest listed release: **3.1.2.1076 (2025-10-31)** [S12].
- A **licence is required to activate Sync v3**. Users without one register on the Resilio site, confirm non-commercial use, and get a free licence. Existing Home Pro and Home Pro for Family licences keep working [S14][S15].
- **Sync Business licences are not compatible with v3**, so commercial users stay on v2 or move to Resilio's business products [S14][S15][S16].
- v2 and v3 stay sync-compatible, but all devices linked to one identity should be on v3 to avoid licence conflicts [S15].
- **Supported v3 Linux CPUs:** x64 and arm64 [S24].
- **Applying the licence in the web UI:** Menu → Licenses → Apply new key, then select the `.btskey` file [S16]. The file picker browses the *container's* filesystem, so first put the `.btskey` somewhere inside a mounted path (e.g. `data/sync/`) and type the in-container path (e.g. `/sync/Sync_Home.btskey`) [S17 (issue #51)]. One user also had to refresh the page before the licence showed as applied (anecdotal) [S17 (issue #51)].
- **Headless alternative:** `rslsync --identity <name>` then `rslsync --license /path/key.btskey`, both pointed at the same storage [S16][S18]. Running these inside the linuxserver container (as user `abc`, with `--storage /config`) is untested here **(unverified)**.

---

## 6. Security

- Docker publishes ports on **all host addresses** (`0.0.0.0`, `[::]`) unless you give a host IP. Docker calls this "insecure by default" [S19b]. Bind the web UI to loopback (`127.0.0.1:8888:8888`). This is what Resilio's own README and Compose example do [S2][S5].
- On Docker releases **before 28.0.0**, hosts on the same L2 segment could reach ports published to `127.0.0.1` [S19b]. Use Docker ≥ 28.
- Docker-published ports **bypass `ufw`** because Docker's NAT rules divert the traffic before ufw sees it [S19]. Don't rely on ufw to hide `8888`. Bind it to loopback instead.
- For remote access, prefer an SSH tunnel (`ssh -L 8888:127.0.0.1:8888 host`) or a TLS reverse proxy (Caddy, Traefik, nginx) on the same Docker network, rather than publishing `8888` **(inference)**. Resilio's docs don't cover reverse proxies (none found in a help-centre search) **(unverified)**.
- **Built-in HTTPS:** set `"force_https": true` in `webui`. Sync then uses a self-signed certificate unless you supply `ssl_certificate` and `ssl_private_key`. The private key must not have a passphrase [S21][S11][S2].
- Keep `allow_empty_password: false`, which is the default in both images [S3][S8].
- Fixed security issue to be aware of: 3.0.1.1414 fixed an XSS in the device name in the UI [S12]. Stay current.

---

## 7. Permissions (PUID/PGID with host-owned `data/`)

- linuxserver containers run the app as internal user `abc`, remapped to `PUID`/`PGID`. Find the values with `id $user`. Don't use `0` (root) [S13].
- At start, the init script runs `lsiown -R abc:abc /config` (recursive) and `lsiown abc:abc /sync` (**top level only**, not recursive) [S8]. Files already under `data/sync/` keep their ownership. If they belong to a different UID, Sync can't write them and you'll see `permission denied`.
- `/downloads` isn't chowned by the init script [S8], so create `data/downloads` yourself as the same user.
- `UMASK` (e.g. `022`, or `002` for group-writable) controls the mode of new files. `UMASK_SET` was deprecated in favour of `UMASK` on 2021-01-20 [S7].
- With the official image, the only way to choose the UID is `--user` / Compose `user: "1000:1000"`. `PUID`/`PGID` are ignored [S3], and the whole `/mnt/sync` tree must then be writable by that UID **(inference)**.

---

## 8. Step-by-step setup (this repo)

### 8.1 Prerequisites

- Docker Engine ≥ 28 with the Compose v2 plugin (`docker compose`). See §6 for why 28 [S19b].
- An x86-64 or arm64 host [S9][S24].
- A Resilio Sync licence for v3: free non-commercial registration, or an existing Home Pro / Family key [S14].
- Router/firewall access if peers are outside the LAN, to forward `55555` TCP+UDP [S10].

### 8.2 Directory layout

```
resilio-sync/
├── compose.yaml
├── .env.example          # committed, placeholders only
├── .env                  # real values, gitignored
└── data/                 # gitignored, runtime only
    ├── config/           # -> /config   (sync.conf, settings.dat, identity, share DB, licence)
    ├── sync/             # -> /sync     (root of all synced folders; one sub-folder per share)
    └── downloads/        # -> /downloads
```

Create it as the user who will own the data:

```bash
mkdir -p data/config data/sync data/downloads
id -u; id -g          # values for PUID / PGID
```

### 8.3 Example `.env.example`

```dotenv
# Image tag: pin to a linuxserver version tag (see https://hub.docker.com/r/linuxserver/resilio-sync/tags)
RESILIO_TAG=3.1.2

# Host user/group that owns ./data (output of `id -u` / `id -g`)
PUID=1000
PGID=1000
UMASK=022
TZ=Etc/UTC

# Web UI: keep on loopback; use an SSH tunnel or reverse proxy for remote access
WEBUI_BIND=127.0.0.1
WEBUI_PORT=8888

# Sync listening port: must match "listening_port" in data/config/sync.conf
SYNC_PORT=55555

# Host paths
CONFIG_DIR=./data/config
SYNC_DIR=./data/sync
DOWNLOADS_DIR=./data/downloads
```

### 8.4 Example `compose.yaml`

```yaml
services:
  resilio-sync:
    image: lscr.io/linuxserver/resilio-sync:${RESILIO_TAG:-latest}
    container_name: resilio-sync
    environment:
      PUID: ${PUID:?set PUID in .env}
      PGID: ${PGID:?set PGID in .env}
      UMASK: ${UMASK:-022}
      TZ: ${TZ:-Etc/UTC}
    volumes:
      - ${CONFIG_DIR:-./data/config}:/config
      - ${SYNC_DIR:-./data/sync}:/sync
      - ${DOWNLOADS_DIR:-./data/downloads}:/downloads
    ports:
      - "${WEBUI_BIND:-127.0.0.1}:${WEBUI_PORT:-8888}:8888/tcp"
      # host port must equal container port (see research note §3)
      - "${SYNC_PORT:-55555}:${SYNC_PORT:-55555}/tcp"
      - "${SYNC_PORT:-55555}:${SYNC_PORT:-55555}/udp"
    restart: unless-stopped
```

Based on linuxserver's example [S7], with the UDP mapping and loopback binding added [S2][S10][S19b]. If you change `SYNC_PORT` from `55555`, also change `listening_port` in `data/config/sync.conf` [S2][S11].

### 8.5 Validate and start

```bash
cp .env.example .env            # then edit PUID/PGID/TZ
docker compose config -q        # validate compose.yaml + .env (no output = OK)
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=50   # expect: Configuration from file "/config/sync.conf" has been applied
```

### 8.6 First run in the web UI

1. Open `http://127.0.0.1:8888/gui/` from the host [S18]. From a remote machine, tunnel first: `ssh -L 8888:127.0.0.1:8888 <host>`.
2. Set the web UI login and password. Linux prompts for them on first open [S18][S21].
3. Set the device name, create the identity, and apply the licence (§5). Put the `.btskey` in `data/sync/` and enter `/sync/<file>.btskey` in the picker [S16][S17].
4. Optional: in Preferences, confirm the listening port is `55555` [S10].

### 8.7 Add or link folders

- **New share from this host:** create `data/sync/<FolderName>` on the host (as the PUID user), then in the web UI use **"+" → Standard folder** and pick `/sync/<FolderName>`. `belowroot` policy means the web UI can't create folders directly in `/sync`, only below it [S8][S11].
- **Join an existing share:** **"+" → "Enter a key or link"** and paste the key or link from the other device [S21][S18]. Choose a destination under `/sync/`.
- **Keys:** read/write vs. read-only keys. A read-only key can be derived with `--get-ro-secret` [S18].

### 8.8 Verify sync

- In the web UI, the folder should show its peers as connected and the transfer completing.
- Drop a test file into `data/sync/<FolderName>` on one side and confirm it appears on the other.
- Check `docker compose logs` for connection errors.
- Confirm the port is listening on the host: `ss -tulpn | grep 55555` (should list both tcp and udp) **(inference)**.

### 8.9 Updating

```bash
# bump RESILIO_TAG in .env (check the Sync change log first) [S12]
docker compose pull
docker compose up -d
docker image prune      # optional; removes dangling images only
```

- Recreate the container from a newly pulled image rather than updating inside it. This is the usual linuxserver guidance, but I didn't re-check it on [S7] **(unverified)**.
- The 2.x → 3.x jump needs a licence and drops Business-licence support. Read Resilio's pre-update notes first [S25].
- Never run `docker compose down -v` in this repo (see `AGENTS.md`).

### 8.10 Backup

- Back up **`data/config/`** (storage: `settings.dat`, identity, share DB, licence, and `sync.conf`) [S8][S26]. Stop the container first for a consistent copy:
  ```bash
  docker compose stop
  tar -czf resilio-config-$(date +%F).tgz -C data config
  docker compose start
  ```
- Synced data in `data/sync/` is replicated to peers, but a peer isn't a backup (deletions propagate). Back it up separately if needed **(inference)**.
- Also keep the share keys and the `.btskey` licence file somewhere safe **(inference)**.

---

## 9. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `permission denied` on `/sync`, `/config` or a sub-folder | `PUID`/`PGID` don't match the host owner of `data/`. Only `/config` is chowned recursively, and `/sync` only at the top level [S8]. Fix the ownership of the specific sub-folder on the host, or correct `PUID`/`PGID` [S13] |
| Web UI unreachable from another machine | Expected: it's bound to `127.0.0.1`. Use an SSH tunnel or reverse proxy (§6) |
| Web UI password lost | Delete `settings.dat` and `settings.dat.old` in `data/config/` with the container stopped, or set credentials in `sync.conf` [S22] |
| Peers not connecting / "relay" only | `55555` TCP **and UDP** not published or forwarded [S10][S7]. Host port ≠ `listening_port` (§3). Host firewall or router not forwarding. Outbound HTTPS to `config.resilio.com` blocked [S10] |
| `ports are not available: exposing port TCP 0.0.0.0:55555 ... /forwards/expose returned unexpected status: 500` (Docker Desktop) | The port is inside a range Windows reserved for Hyper-V/WinNAT. Check with `netsh int ipv4 show excludedportrange protocol=tcp` (and `protocol=udp`). Seen on this host on 2026-10-04: TCP `55528-55627` and UDP `55510-55609` were reserved. These ranges are taken from the dynamic range (`49152-65535` by default) and change across reboots. Fix: pick a `SYNC_PORT` below `49152` (this repo uses `44555`) and set `listening_port` to match, or reserve the port yourself as admin (`net stop winnat`, `netsh int ipv4 add excludedportrange ...`, `net start winnat`) **(observed)** |
| Peers on the same LAN not found | Multicast discovery doesn't cross the bridge network **(inference)**. Make sure the tracker is reachable, or add known hosts, or use `network_mode: host` [S10][S11] |
| Changes only picked up after rescan | inotify watcher limit. Raise `fs.inotify.max_user_watches` on the host [S23] |
| Licence picker "does nothing" | Use an in-container path under a mounted volume (`/sync/...`), then refresh the page [S17] |
| Log spam `TLSPSK… Supported ciphers` | Known report against the linuxserver image (2025), unresolved upstream. Cosmetic [S17 (issue #55)] |
| Image still on an older Sync version | linuxserver builds only what Resilio publishes to its apt repo [S17 (issue #52)] |

### WSL2 notes (this repo is developed on WSL2)

- In WSL2's default **NAT** networking, apps are reachable from Windows via `localhost`, but **not from the LAN**. Inbound access needs `netsh interface portproxy` on Windows [S20]. Port proxy is TCP-only **(unverified)**, so it won't help with Sync's UDP traffic.
- **Mirrored networking** (`networkingMode=mirrored` under `[wsl2]` in `.wslconfig`, Windows 11 22H2+) allows LAN access to WSL directly and supports multicast. Inbound connections may also need a Hyper-V firewall rule (`Set-NetFirewallHyperVVMSetting … -DefaultInboundAction Allow` or `New-NetFirewallHyperVRule`) [S20].
- Because of the above, a WSL2 host works best as a peer that connects **out** (via tracker/relay) unless mirrored mode plus firewall rules are set up **(inference)**.
- Keep `data/` on the Linux filesystem (e.g. `~/...`), not under `/mnt/c`. inotify file-change notifications are unreliable across the Windows/9p boundary **(unverified, not checked against MS docs in this research)**.

---

## 10. Open questions and uncertainties

1. **Official Docker status.** The Sync 3.0 change log says Docker support is deprecated [S12], while the official repo isn't archived and its README is unchanged [S2]. Treat `resilio/sync` as unmaintained.
2. **Headless licensing inside linuxserver.** `--identity`/`--license` [S16][S18] haven't been tested with the s6 service already running. The web UI path is confirmed only by user reports [S17].
3. **`listening_port` precedence.** It's not documented whether a value changed in web UI Preferences survives a restart when `sync.conf` also sets `listening_port`. Keep them identical.
4. **Host networking.** Whether `network_mode: host` restores LAN multicast discovery for this image is reasoned, not tested.
5. **linuxserver `/downloads`.** It's set as `files_default_path` but isn't in `dir_whitelist` and isn't chowned [S8]. Its practical use in the web UI is unclear.

---

## Sources

All accessed 2026-10-04. Help-centre "edited" dates come from the Zendesk API metadata.

- **[S2]** bt-sync/sync-docker README (official): https://github.com/bt-sync/sync-docker (last commit 2024-06-03)
- **[S3]** Official Dockerfile, `run_sync`, `sync.conf.default`: https://github.com/bt-sync/sync-docker/blob/master/Dockerfile · https://github.com/bt-sync/sync-docker/blob/master/run_sync · https://github.com/bt-sync/sync-docker/blob/master/sync.conf.default
- **[S4]** Docker Hub `resilio/sync` (tags API: latest/2.8.1 pushed 2024-06-03, amd64 only): https://hub.docker.com/r/resilio/sync · https://hub.docker.com/v2/repositories/resilio/sync/tags
- **[S5]** Official Compose example: https://github.com/bt-sync/sync-docker/tree/master/docker-compose
- **[S7]** linuxserver docs page: https://docs.linuxserver.io/images/docker-resilio-sync/
- **[S8]** linuxserver repo (Dockerfile, `root/defaults/sync.conf`, s6 `init-resilio-sync-config/run`, `svc-resilio-sync/run`, `readme-vars.yml`): https://github.com/linuxserver/docker-resilio-sync
- **[S9]** Docker Hub `linuxserver/resilio-sync` tags (3.1.2, ls261, 2026-09-29, amd64+arm64): https://hub.docker.com/r/linuxserver/resilio-sync/tags
- **[S10]** Resilio: What ports and protocols are used by Sync? (edited 2024-05-29): https://help.resilio.com/hc/en-us/articles/204754759-What-ports-and-protocols-are-used-by-Sync
- **[S11]** Resilio: Running Sync in configuration mode (edited 2025-11-13): https://help.resilio.com/hc/en-us/articles/206178884-Running-Sync-in-configuration-mode
- **[S12]** Resilio Sync 3.0 change log (edited 2025-10-31): https://help.resilio.com/hc/en-us/articles/31386579044755-Resilio-Sync-3-0-change-log
- **[S13]** linuxserver: Understanding PUID and PGID: https://docs.linuxserver.io/general/understanding-puid-and-pgid/
- **[S14]** Resilio: Licensing in Resilio Sync 3.0 (edited 2024-10-10): https://help.resilio.com/hc/en-us/articles/31116248751123-Licensing-in-Resilio-Sync-3-0
- **[S15]** Resilio: FAQ Resilio Sync 3.0.0 (edited 2024-09-02): https://help.resilio.com/hc/en-us/articles/32109883606035-FAQ-Resilio-Sync-3-0-0
- **[S16]** Resilio: How to apply license key and share license seats (edited 2025-06-20): https://help.resilio.com/hc/en-us/articles/204762369-How-to-apply-license-key-and-share-license-seats
- **[S17]** linuxserver/docker-resilio-sync issues #47, #51, #52, #55: https://github.com/linuxserver/docker-resilio-sync/issues/47 · https://github.com/linuxserver/docker-resilio-sync/issues/51 · https://github.com/linuxserver/docker-resilio-sync/issues/52 · https://github.com/linuxserver/docker-resilio-sync/issues/55
- **[S18]** Resilio: Guide to Linux, and Sync peculiarities (edited 2024-07-26): https://help.resilio.com/hc/en-us/articles/204762449-Guide-to-Linux-and-Sync-peculiarities
- **[S19]** Docker docs: Packet filtering and firewalls (ufw bypass): https://docs.docker.com/engine/network/packet-filtering-firewalls/
- **[S19b]** Docker docs: Port publishing and mapping: https://docs.docker.com/engine/network/port-publishing/
- **[S20]** Microsoft Learn: Accessing network applications with WSL (updated 2026-06-02): https://learn.microsoft.com/en-us/windows/wsl/networking
- **[S21]** Resilio: Configuring WebUI (edited 2024-04-02): https://help.resilio.com/hc/en-us/articles/115001184490-Configuring-WebUI
- **[S22]** Resilio: How do I reset my WebUI password? (edited 2025-03-13): https://help.resilio.com/hc/en-us/articles/205450295-How-do-I-reset-my-WebUI-password
- **[S23]** Resilio: Agent run out of system notify watchers (edited 2020-09-17): https://help.resilio.com/hc/en-us/articles/360015593120
- **[S24]** Resilio: Supported platforms and system requirements (edited 2025-12-04): https://help.resilio.com/hc/en-us/articles/205450965-Resilio-Sync-supported-platforms-and-system-requirements
- **[S25]** Resilio: Important before updating to Resilio Sync 3.0.0 (edited 2025-10-29): https://help.resilio.com/hc/en-us/articles/31193941051795-Important-before-updating-to-Resilio-Sync-3-0-0
- **[S26]** Resilio: Sync Storage folder (edited 2022-04-29): https://help.resilio.com/hc/en-us/articles/206664690-Sync-Storage-folder
