# Making Resilio Sync propagate changes faster

Research note on change-to-peer latency (first priority) and throughput (second priority) for this repo's stack.

- **Researched:** 2026-10-04
- **Scope:** what causes the 8–10 s delays measured with `scripts/sync-latency.sh`, which Sync settings affect latency or throughput, LAN tuning, the Windows ↔ container asymmetry, environment options (networking, filesystems, debug logging), how representative a same-PC test is, and alternatives.
- **Source rules:** every claim cites a source (see [Sources](#sources)). Statements marked **(inference)** are my own reasoning, not something a source says. Statements marked **(unverified)** were not confirmed against a primary source. **[L1]** is local evidence: the Windows peer's own debug log from the test run (see §2). It's primary evidence for this machine, but it isn't Resilio documentation.

---

## 1. TL;DR

| Finding | Evidence |
|---|---|
| **The main cause of the 8–10 s delays is a roughly 10-second throttle on how often a peer tells the other peer that its folder tree has changed.** The first change after an idle period goes out at once. Any change within about 10 s of the previous notification waits for the next 10-s slot. Resilio doesn't document this behaviour, and I found no setting for it. | [L1]: `StateNotify` fires `immediately` only when ≥ 15.8 s have passed since the previous one. Otherwise it fires on a `timer` 9.42–10.47 s after the previous one (39 samples). Container-initiated merges arrive every ~9.5–9.7 s during the test |
| **`scripts/sync-latency.sh` mostly measures that throttle.** It runs its six cases back to back, so every case after case 1 lands inside the previous case's 10-s window. That's why case 1 took 1.5 s and the rest took 8–16 s. | [L1] + the script's structure (inference) |
| Moving data is not the bottleneck. On the receiving side, the 10 MB file downloaded in **0.14 s** (≈148 MB/s), and each small file took ≈0.12 s. | [L1] |
| The documented "10 s delay" (`FileDelayConfig`) **doesn't apply to Markdown**. It only covers the listed extensions (Office, AutoCAD, Adobe and similar), and this machine's file has no `*.md` entry. | [R3][F3], local `FileDelayConfig` [L1] |
| `folder_rescan_interval` is the fallback for missed notifications, not the trigger for normal changes. Lowering it won't help while notifications work, and very low values hurt. | [R2][F2] |
| `lan_encrypt_data`, `prefer_utp2_lan`, rate limits and the disk/thread settings affect **throughput or CPU**, not change-to-peer latency. Throughput is already far more than an 80 MB vault needs. | [R1][R4], [L1] |
| On this machine, the peer-to-peer path goes through Docker Desktop's port forwarding. Sync reports an RTT of ≈68 (probably ms) to a peer on the same PC, and merge steps are ≈62 ms apart. That makes many small files slow (≈2 round trips per file). On a real LAN this should be much lower **(inference)**. | [L1][D3] |
| Windows → container (B→A) isn't slow because of file notifications. Windows saw the new file at once, and the container side uses inotify on a WSL ext4 bind mount, which works. The asymmetry is mostly where each case falls in the 10-s cycle, plus a 0.3–3.5 s local settle delay before Sync indexes the change. | [L1][D1] |
| For sub-second latency, Resilio Sync isn't the right tool. Community reports since 2013 describe a ~10 s floor, and I found no documented knob. Syncthing (`fsWatcherDelayS`) or a dedicated dev-sync tool are the documented alternatives. | [F1][A1][A2] |

---

## 2. Method and local evidence

The Windows peer (B) has debug logging enabled. `%APPDATA%\Resilio Sync\debug.txt` contains `FFFFFFFF`, which turns on full logging [R13]. Its `sync.log` covers the latency run from 2026-10-04 12:11:03 to 12:12:12 local time (UTC+7). I read that log to time each step on B's side. I didn't read the container's log from the test: the container restarted at 05:25 UTC, which dropped the earlier `docker logs` output, and its storage folder is under `data/`, which this repo forbids reading. So **A's internal timings are inferred from what B received**.

Timeline of case 2, *new small file B → A*, from B's log [L1]:

| Time (B) | Δ | Event |
|---|---|---|
| 12:11:04.282 | 0 | `[SyncFolderNotify] Event: FA_ADDED … note-b.md`: Windows reports the file right away |
| 12:11:07.730 | +3.45 s | `fs event for entry …` → `NewEntryJob` → `new entry … hash:761B…`: Sync processes the event and indexes the file |
| 12:11:12.839 | +8.56 s | `ScheduledTask: "StateNotify" invoked: timer, reason:OnLocalTreeChanged` → `Going to send state notify to peer` (9.42 s after the previous notify at 12:11:03.421) |
| 12:11:12.958 | +8.68 s | A connects back: `created incoming merge`, `get_root`, `get_nodes /`, `get_nodes /_sync-latency-test`, `get_files` (each step ≈62 ms apart) |
| 12:11:13.268 | +8.99 s | A logs in to download `note-b.md` (B seeds it) |

That's ≈9 s in total, close to the 8.3 s the script measured. Clocks differ slightly between WSL and Windows. Of the ≈9 s, ≈5.1 s is the wait for the 10-s `StateNotify` slot and ≈3.45 s is local settle and indexing time.

Pattern across the whole run [L1]:

- **StateNotify (B → A):** 39 `timer` invocations, each 9.42–10.47 s after the previous one. 18 `immediately` invocations, each ≥ 15.84 s after the previous one.
- **Merges started by A (A → B):** 12:11:03.36, 12.96, 22.50, 32.00, 41.67, 51.13, 12:12:00.87 and 10.60, so about every 9.5–9.7 s while the test kept changing files. The edit in case 3 landed at B at 12:11:23.08, right after the 22.50 merge. The 50-file batch started arriving after the 32.00 merge. The 10 MB file arrived with the 51.13 merge. Each case's latency is consistent with "wait for A's next ~10-s slot" **(inference, since A's log wasn't available)**.
- **Transfer itself is fast:**
  - `big.bin` (10 MB): metadata at 12:11:51.188, `DOWNLOAD` at 51.377, finished at 51.515. Sync logged `speed:147831356` (≈148 MB/s).
  - The 50 batch files: downloaded one after another, ≈123 ms each (12:11:33.22 → ≈39.3). Each one does a connect, then `send login` (≈60 ms), then `all data received` (≈60 ms).
  - The first download after a merge also waits ≈0.6 s for a `ConnectMorePeers` timer (12:11:03.422 → 04.044).

---

## 3. Q1: what causes the delay, and which settings control it

### 3.1 Documented mechanisms

1. **Change detection.** Sync detects changes through filesystem notifications, a scheduled rescan (`folder_rescan_interval`, default 600 s, also run at startup), or a manual rescan. "When FS notifications work properly, Sync starts processing file immediately after the update" [R2]. The rescan only compares mtime and size, then rehashes changed files [R2]. On Linux, each watched directory uses one inotify watch. If Sync runs out of watches, changes are only picked up by the periodic rescan [R12]. The container log shows `SyncFolderNotify: Added path=/sync/vaults/ideaverseos-pkm_vault with fd=5`, so notifications are active there [L1 container log].
2. **Per-extension delay (`FileDelayConfig`).** Since 2.2.0, Sync can delay syncing "certain types of files". You edit the JSON file `FileDelayConfig` in the storage folder and restart. "By default, the delay time for all types of files is set to 10 seconds" [R3]. It has worked on POSIX since 2.6.0, with a fix in 2.7.0 [R17]. A forum user notes that the "all types" wording only means the extensions listed by default; other extensions have to be added by hand [F3]. This machine's Windows file lists `*.accdb, *.doc, *.docx, *.dwg, *.dxf, *.indd, *.laccdb, *.ppt, *.pptx, *.psd, *.stl, *.vsd, *.xls, *.xlsx, root_acl_entry`, all set to 10 [L1]. **`.md` isn't listed, so this delay doesn't affect an Obsidian vault (inference).**
3. **Merge.** Peers "exchange and compare their files/folders metadata" before syncing ("Merging folder tree"), and "Syncing speed may be slower if Agent performs merge at the moment" [R7].
4. **Undocumented ~10-s state-notification throttle.** Described in §2. I found no help-centre article, change-log entry or power-user setting that names it. Community forum posts from the BitTorrent Sync era describe a fixed ~10 s "settling" delay that "cannot be controlled" [F1]. Those posts aren't from staff and predate 2.x, so treat them as **(unverified)** context.

### 3.2 The advanced settings this machine reports

Definitions are from Resilio's power user reference [R1] unless noted. The "Latency / throughput" column is **(inference)** unless a source is cited.

| Setting (current value) | What Resilio says it does | Latency / throughput |
|---|---|---|
| `enable_file_system_notifications` (true) | "Enables/disables operating system notifications about file update" [R1] | **Keep `true`.** Without it, changes are found only by rescan (600 s) [R2] |
| `lazy_indexing` (true) | "Works only in Sync Business. … won't calculate hash of file until remote peer requests it" [R1] | Probably a no-op on a free v3 licence. No effect on latency |
| `folder_rescan_interval` (600) | Rescans for changes "it could miss with other means". `0` disables rescan, even on restart [R1][R2] | None while notifications work. Very low values make Sync keep re-indexing and can slow it down [F2]. Leave at 600 |
| `lan_encrypt_data` (true) | "Forces to encrypt all Sync data flowing in LAN" [R1]. Resilio lists disabling it as a speed tip because "Encryption … takes a lot of resources" [R4] | Throughput and CPU only. Not a bottleneck here (≈148 MB/s observed [L1]). B's tunnels to A show `enc: TLS-PSK` [L1] |
| `prefer_utp2_lan` (false) | "Enabled WAN optimization in LAN as well" [R1] | uTP2 is a WAN-optimised protocol [R6]. No latency benefit expected on LAN or loopback |
| `net.enable_utp2` (true) | "Enables WAN optimization. Works only if WAN feature is present in license (for legacy licenses)" [R1] | None here |
| `direct_torrent_enabled` (true) | Files "smaller than current speed" aren't split into pieces, so fewer requests are needed. An interrupted transfer restarts from the beginning [R1] | Helps small-file latency. **Keep `true`.** The log shows `removing direct torrent for file` on each small file [L1] |
| `disk_worker_pool_size` (1) | Threads per disk. Helps "high-latency CIFS" and fast SSD/RAID [R1] | Throughput on network or fast storage only. Not relevant for one small file |
| `parallel_indexing` (false) | Rescans all shares at once, which "may cause heavy disk and CPU usage" [R1] | Only matters with several shares rescanning together |
| `prioritize_initial_indexing` (true) | "Applies only to initial rescan on pre-seeded folders" [R1] | None after the first index |
| `folder_defaults.lan_discovery_mode` (3) | 0 disabled, 1 multicast, 2 broadcast, 3 both [R1] | Only affects finding peers. Doesn't work through Docker's bridge network (see §4) |
| `use_tracker` / `use_relay` (true) | Tracker finds peer IPs. Relay is a fallback that "can impair the syncing speed" [R9] | No effect while a direct tunnel exists. The connection here is direct [L1] |
| `tunnel_protocols` ("utp;utp2;tcp;relay;inproc") | "Forces peer to use this or that protocol". Peers need a protocol in common [R1] | The log shows the best tunnel is `TCP (TLS-PSK)` between the two peers [L1]. Restricting it isn't expected to change latency |
| `rate_limit_local_peers` (false) | "Limits LAN bandwidth". Global rate limits apply only to Internet peers unless this is true [R1][R8] | **Keep `false`** [R4] |
| `worker_threads_count` (0) | Indexing threads. 0 means use all cores [R1] | Already at maximum |
| `max_packet_size` (32) | Max size of a service-data packet (tree nodes, ACLs) [R1] | Not a latency knob |
| `transfer_job_verify_downloaded_files` (false) | Re-hash after writing. "Works for file send option". May add disk load [R1] | Keep `false` |
| `disk_low_priority` (false) | "Forces all disk read-write operations to low priority" [R1]. Resilio recommends `false` for speed [R4][R5] | Keep `false` |
| `prefer_net_over_disk_operations` (false) | Re-download instead of computing differences [R1] | Could help large rewritten files on a fast link. Irrelevant for small notes |
| `sync_extended_attributes` (true) | Syncs xattrs and alternate streams [R1] | Probably negligible. Setting it to `false` would avoid xattr work across ext4 ↔ NTFS **(unverified benefit)** |

Two other documented knobs are worth knowing:

- `recheck_locked_files_interval` (600 s): a file locked by another app is retried after this interval [R1]. This applies if Obsidian or an antivirus holds a lock **(inference)**.
- `folder_defaults.transfer_priority`: download ordering only [R19].

**Bottom line for Q1:** none of the documented settings controls the ~10-s state-notification throttle, and no documented setting reduces the 0.3–3.5 s local settle time. Settings mainly let you avoid making things *worse*: keep notifications on, keep `direct_torrent_enabled` on, and leave rate limits off.

---

## 4. Q2: LAN-specific speedups

- **Direct connection over relay** is Resilio's first speed tip [R4][R5]. That's already true here: tunnels are direct [L1].
- **`lan_encrypt_data=false`** is documented as a throughput tip [R4]. It saves CPU on large transfers. It won't touch the 10-s cycle. Set it on both peers if you test it **(inference; the docs don't say whether one side is enough)**.
- **Predefined hosts plus "Search LAN" off:** "assign static IPs … use the 'pre-defined hosts' settings … untick the 'Search LAN' option … Sync will then know exactly where to connect" [R4]. Predefined hosts are per folder, are a list of `IP:port` (or `DNS:port`) pairs, and should be set "on all peers" [R9]. The config-mode key is `known_hosts`, or `folder_defaults.known_hosts` as a power-user default [R1][R11]. This speeds up **discovery and reconnects**, and removes the dependency on the tracker. B's log shows tracker trouble at 12:11:00 (`connection declined`, `There's no connection to tracker`) [L1]. It doesn't shorten per-change latency once the tunnel is up **(inference)**.
  - For this same-PC setup:
    - **On B (Windows):** add `127.0.0.1:44555`. Docker Desktop's backend listens on the published host port [D3].
    - **On A (the container):** add `host.docker.internal:<B's listening port>` [D4].
- **LAN-only syncing:** disable tracker and relay per share and in power-user settings. Optionally set `service_folders.use_relay`/`use_tracker` to false in `sync.conf`, and clear cached global IPs by setting peer expiration to 0, restarting, then setting it back [R10].
- **TCP vs uTP:** Sync tries uTP (UDP), uTP2 and TCP [R1][R6]. The best tunnel here is TCP [L1]. I found no documentation saying one protocol has lower latency than the others.
- **Rate limits:** check that no send/receive limits are set (Preferences → Advanced) and that `rate_limit_local_peers=false` [R4][R8]. Both already hold here.

---

## 5. Q3: why B→A (Windows → container) differs from A→B

- **Windows notifications are immediate.** B's log shows `SyncFolderNotify FA_ADDED` within a millisecond of the write [L1]. `ReadDirectoryChangesW` only loses detail when its buffer overflows; the caller must then enumerate the directory [M3]. That isn't a factor for a single file.
- **Container notifications work** because the vault is bind-mounted from the WSL ext4 filesystem. Docker: "Linux containers only receive file change events, 'inotify events', if the original files are stored in the Linux filesystem". Data under `/mnt/c` would lose them, and performance is "much higher" from the Linux filesystem [D1]. Microsoft gives the same storage advice [M2].
- **What actually differs:**
  1. **Where the change falls in the sender's ~10-s cycle.** Case 1 (A→B) came after an idle period, so A notified at once (1.5 s). Case 2 (B→A) came 0.9 s after B had just sent a notify for the downloaded `note-a.md` (12:11:03.421), so it waited until 12:11:12.839 [L1].
  2. **Local settle time on the sender.** On B, event-to-index time was 0.3–1.1 s for most earlier events but 3.45 s for `note-b.md` [L1]. Nothing documented explains the variation **(unverified cause)**.
  3. **Reading B from WSL through `/mnt/c`.** The script reads B through `/mnt/c` (9P), which adds polling overhead. That's small compared with 0.2 s polling **(inference)**.
- To see A's side directly, capture `docker compose logs` during a run. The container's debug log goes to stdout (the startup lines `Debug log mask has been set to FFFFFFFF` appear in `docker logs`) [L1]. Then grep for `StateNotify`, `fs event` and `SyncFolderNotify`.

---

## 6. Q4: environment-level options

| Option | What sources say | Expected effect here |
|---|---|---|
| Keep data on WSL ext4 (current) | inotify events reach Linux containers only from the Linux filesystem, and performance is higher there [D1][M2] | Already optimal. **Don't move the vault to `/mnt/c`**: notifications would stop and Sync would fall back to the 600-s rescan [R2][D1] **(inference)** |
| `network_mode: host` | Docker Desktop supports host networking from 4.34 (Settings → Resources → Network → Enable host networking). It works at layer 4, so protocols below TCP/UDP aren't supported, and it doesn't work with Enhanced Container Isolation [D2] | On Docker Desktop, "host" means the Docker VM, and connections to Windows still go through the backend [D3] **(inference)**. Might remove a hop for container ↔ Windows traffic, but probably not the ~60 ms RTT. Worth one test at most. Won't affect the 10-s cycle |
| WSL mirrored networking (`networkingMode=mirrored` in `.wslconfig`) | Adds multicast support and direct LAN → WSL connections. Needs a Hyper-V firewall rule for inbound traffic [M1] | Affects WSL distros. Docker Desktop's own VM networking is separate [D3], so whether it changes the container path is **(unverified)**. Mainly matters for real LAN peers reaching this PC, not for latency |
| Debug logging off | Debug logging is enabled by Preferences → Advanced → "Enable debug logging", or by a `debug.txt` file containing `FFFFFFFF` in the storage folder, followed by a restart [R13][R14]. Logs rotate at `log_size` (100 MB) [R1][R15] | Resilio doesn't quantify the overhead. With mask `FFFFFFFF`, B wrote ≈147k lines (29 MB) within hours [L1], so turning it off should cut disk writes **(inference)**. To disable: untick the option, or remove or rename `debug.txt` (Windows: `%APPDATA%\Resilio Sync\debug.txt` [R16]; container: storage path `/config`, i.e. `data/config/debug.txt` [R16][S8 of the Docker note]), then restart. Removing the file is **(unverified)**; Resilio only documents creating it. Keep debug logging on while you measure. It's your only window into the 10-s cycle |
| Disk/CPU | Overloaded disks or high latency slow sync, and the Performance graphs show disk queue and RTT [R6]. `disk_low_priority=false` [R4][R5] | Not the limit for an 80 MB vault [L1] |
| Windows Defender / security software | Resilio: security software "may block/delay data transfer or the re-checking of the files" [R5] | Could add per-file delay on B **(unverified for this PC)** |

---

## 7. Q5: is a same-PC test representative?

- **The ~10-s state-notification cycle and the per-file settle time are Sync-core behaviour.** They would apply between two real devices too **(inference: they come from Sync's scheduler, not the network)**.
- **The network path isn't representative.** A container's published ports are served by Docker Desktop's backend process, which forwards into the VM [D3]. B's log shows Sync's RTT figure at ≈68,000 (units undocumented, likely µs ≈ 68 ms) and ≈60 ms between merge steps [L1]. On a wired LAN the RTT is usually ≈1 ms or less **(inference)**. Batch transfers (≈2 round trips per small file [L1]) should then be much faster, and a merge would take milliseconds instead of ≈0.3 s.
- Both peers also share one disk, CPU and antivirus, so throughput figures understate a two-machine setup **(inference)**.
- **Realistic cross-device expectation:**
  - **Isolated edit** (nothing synced in the previous ~10–15 s): about 1–2 s detection-to-arrival. Case 1 is the best proxy.
  - **Continuous edits** (for example an editor autosaving every few seconds): about one update per ~10 s per peer.
  - Both figures are **(inference from [L1])**.
- Resilio itself says "many small files" transfer slower than a few large ones [R5].

---

## 8. Q6: alternatives if sub-second latency is a hard requirement

- **Syncthing:** its file watcher accumulates changes for `fsWatcherDelayS` before scanning (the docs' example value is 10). It's configurable per folder, and `fsWatcherTimeoutS` caps continuous changes [A1]. Unlike Resilio's cycle, this is a documented, tunable knob.
- **Mutagen** (developer-focused file sync, often used with containers): uses native recursive watching on macOS and Windows. On Linux it polls, with native watches on recently changed content. The default polling interval is 10 s and can be changed [A2].
- Resilio forum users asked for "below 1 sec" sync in 2014 and were told it "isn't currently possible" [F1] (community answer, **(unverified)** for v3).

---

## 9. Prioritised experiments

All experiments use `scripts/sync-latency.sh <vault-on-A> <vault-on-B>` (A = the WSL path bind-mounted into the container, B = the Windows vault via `/mnt/c/...`). Change one thing at a time, run the script **three times with ≥ 30 s idle before each run**, and keep debug logging on until the last experiment. Restart Sync after power-user or `sync.conf` changes; Resilio says this is needed for `FileDelayConfig` and profiler changes, and it's safest for the rest [R1][R3].

| # | Change | Where | Expected effect | How to measure |
|---|---|---|---|---|
| 1 | **Nothing. Re-measure with idle gaps.** Run each case in isolation with ≥ 15 s of idle before it, either by running the script repeatedly and keeping only the first row, or by adding `sleep 15` between cases in a local copy of the script | Test method only | Cases 2, 3, 5 and 6 should drop from 8–12 s to ≈1–4 s, confirming the 10-s cycle is the dominant cost **(inference)** | Compare per-case seconds with the current 1.5 / 8.3 / 10.3 / 16.1 / 12.2 / 9.7. In B's `sync.log`, check that `StateNotify` says `immediately` |
| 2 | Capture A's side of the timeline | `docker compose logs -f --since 1m > /tmp/a.log` during a run (read-only) | Confirms A has the same 9.4–10.5 s `StateNotify` timer and shows A's notify → `fs event` settle time | `grep -E 'StateNotify|fs event|SyncFolderNotify' /tmp/a.log` and line up with the script's timestamps |
| 3 | Predefined hosts on both peers, "Search LAN" off | Web UI / desktop: folder ⋯ → Preferences → Use predefined hosts. A: `host.docker.internal:<B port>`. B: `127.0.0.1:44555` [R9][D4]. Or `known_hosts` in `sync.conf` [R11] | Faster and more robust reconnects. No dependency on the tracker. Little change to steady-state latency | Restart one peer and time until it shows connected. Then rerun experiment 1 |
| 4 | `lan_encrypt_data=false` on both peers | Preferences → Advanced → Power user preferences (desktop), or in `sync.conf` [R1][R11] | Lower CPU per byte, possibly faster large-file throughput [R4]. No change to small-file latency **(inference)** | Case 5 (10 MB) and case 4. Check `enc:` in tunnel log lines |
| 5 | Debug logging off on both peers | Preferences → Advanced → untick "Enable debug logging", or remove `debug.txt` from the storage folder, then restart [R13][R14] | Less disk I/O. Small latency gain at most **(inference)** | Rerun experiment 1. You lose log visibility, so do this last |
| 6 | Docker Desktop host networking (`network_mode: host`, remove `ports:`) | `compose.override.yaml` + Docker Desktop Settings → Resources → Network [D2] | Maybe lower container ↔ Windows RTT. No effect on the 10-s cycle. Web UI binding must then come from `webui.listen` | Case 4 (50 files), and `rtt:` values in B's log |
| 7 | (Only if notifications seem missed) check inotify watches | `cat /proc/sys/fs/inotify/max_user_watches` in WSL. Raise it via `sysctl` [R12] | Avoids falling back to the 600-s rescan in large vaults | Look for "run out of system notify watchers" warnings [R12]. Cases 3 and 6 timing out near 600 s would also point to this |

Not worth testing:

- Lowering `folder_rescan_interval` [R2][F2]
- `prefer_utp2_lan` or `net.enable_utp2` [R1]
- `disk_worker_pool_size` or `parallel_indexing` (built for other storage cases) [R1]
- `FileDelayConfig` for `.md`, since it's already not listed [R3][L1]

---

## 9a. Results: run 2 (experiments 1 and 2, 2026-10-04 05:33 UTC)

`scripts/sync-latency.sh <A> <B> 180 15` (15 s idle before each case), with `docker compose logs` captured for the run. A = container, B = Windows.

| Case | Run 1 (no idle) | Run 2 (15 s idle) |
|---|---|---|
| 1. new small file A → B | 1.5 s | 1.5 s |
| 2. new small file B → A | 8.3 s | 3.1 s |
| 3. edit existing file A → B | 10.3 s | 5.4 s |
| 4. 50 small files A → B | 16.1 s | 13.0 s |
| 5. 10 MB file A → B | 12.2 s | 9.9 s |
| 6. delete file A → B | 9.7 s | 4.8 s |

What the container log shows **(observed, this run)**:

- **The ~10 s cycle is the `SyncState` scheduled task.** It logs `ScheduledTask: "SyncState" invoked: immediately` only when enough time has passed since the last run (05:33:23, 05:34:51); otherwise `invoked: timer`, at 8.5–12.8 s intervals (05:33:33, :41, :51, 05:34:01, :10, :20, :30, :39). Each run starts a state merge with the peer (`Going to sync state with peer ...`), after which the peer fetches the file within ~0.1–0.3 s.
- **A 15 s idle isn't always enough.** The timer kept firing on `OnReceivedStateNotify` (the Windows peer's own announcements) and on the previous case's changes, so case 3 still waited for a timer slot: inotify 05:33:56.946 → indexed 05:33:57.789 (0.8 s) → `SyncState` timer 05:34:01.798 (4.0 s) → peer fetch 05:34:02.046.
- **Large new files wait before indexing.** Case 5: inotify `IN_CREATE` at 05:34:42.718, but the entry was only indexed at 05:34:51.963 (9.2 s, nothing logged in between). `SyncState` then ran `immediately` and the peer fetched it 0.25 s later. Small files were indexed 0.8–1.0 s after the event. The cause of the 9.2 s wait is not documented **(open question)**.
- **Inotify works through the bind mount:** every write produced `SyncFolderNotify` events within ~3 ms.

Conclusion **(inference)**: for a single isolated note edit, expect ~1–2 s; for edits during ongoing activity on either peer, expect up to one `SyncState` period (~10 s); new large files add a pre-index wait. None of the reported advanced settings names `SyncState` or this wait.

## 10. Open questions

1. The ~10-s `StateNotify` minimum interval comes from the log, not from documentation. I found no setting for it. Whether a hidden `sync.conf` key exists is **(unverified)**.
2. B's 3.45 s notify → index delay for `note-b.md`, against 0.3–1.1 s elsewhere, is unexplained.
3. A-side (container) timings weren't captured for the test run; experiment 2 fills this gap.
4. The units of Sync's `rtt:` log field aren't documented.

---

## Sources

All accessed 2026-10-04. Help-centre "edited" dates come from the Zendesk API (`/api/v2/help_center/en-us/articles/<id>.json`), because the web pages may return 403. forum.resilio.com returned 403, so I read the forum threads through the Internet Archive (snapshot dates given).

**Resilio help centre**

- **[R1]** Power user preferences (edited 2025-07-10): https://help.resilio.com/hc/en-us/articles/207371636-Power-user-preferences
- **[R2]** How soon does synchronization start? (edited 2025-09-18): https://help.resilio.com/hc/en-us/articles/204754319-How-soon-does-synchronization-start
- **[R3]** Setting Delay Time For Syncing (edited 2017-08-07): https://help.resilio.com/hc/en-us/articles/207491426-Setting-Delay-Time-For-Syncing
- **[R4]** How can I improve data transfer/sync speed? (edited 2018-11-29): https://help.resilio.com/hc/en-us/articles/204762319-How-can-I-improve-data-transfer-sync-speed
- **[R5]** Download/upload speed is very slow (edited 2018-08-06): https://help.resilio.com/hc/en-us/articles/205450195-Download-upload-speed-is-very-slow
- **[R6]** Performance overview (edited 2023-06-16): https://help.resilio.com/hc/en-us/articles/360001331930-Performance-overview
- **[R7]** Some internal tasks are taking time to complete (edited 2020-07-30): https://help.resilio.com/hc/en-us/articles/360015586600
- **[R8]** Sync Preferences (edited 2024-08-12): https://help.resilio.com/hc/en-us/articles/204762669-Sync-Preferences
- **[R9]** Folder Preferences (edited 2025-07-10): https://help.resilio.com/hc/en-us/articles/205458125-Folder-Preferences
- **[R10]** Can I force Sync to do local network (LAN) syncing only…? (edited 2018-10-19): https://help.resilio.com/hc/en-us/articles/204754349
- **[R11]** Running Sync in configuration mode (edited 2025-11-13): https://help.resilio.com/hc/en-us/articles/206178884-Running-Sync-in-configuration-mode
- **[R12]** Agent run out of system notify watchers (edited 2020-09-17): https://help.resilio.com/hc/en-us/articles/360015593120
- **[R13]** Collecting debug logs manually (edited 2025-02-05): https://help.resilio.com/hc/en-us/articles/206664730-Collecting-debug-logs-manually
- **[R14]** Collecting debug logs automatically (edited 2025-01-03): https://help.resilio.com/hc/en-us/articles/360019430539
- **[R15]** Increasing Debug Log size (edited 2018-08-06): https://help.resilio.com/hc/en-us/articles/205450145-Increasing-Debug-Log-size
- **[R16]** Sync Storage folder (edited 2022-04-29): https://help.resilio.com/hc/en-us/articles/206664690-Sync-Storage-folder
- **[R17]** Resilio Sync change log, 2.x (edited 2024-06-03; entries 2.2.0 "configurable delay … certain extensions", 2.6.0/2.7.0 "FileDelayConfig … posix"): https://help.resilio.com/hc/en-us/articles/206216855-Resilio-Sync-change-log
- **[R18]** Resilio Sync 3.0 change log (edited 2025-10-31; 3.1.2.1076 lists only UI and "minor core bugfix"): https://help.resilio.com/hc/en-us/articles/31386579044755-Resilio-Sync-3-0-change-log
- **[R19]** File download priority (edited 2025-07-10): https://help.resilio.com/hc/en-us/articles/42328167759251-File-download-priority

**Resilio forum** (community posts, not staff)

- **[F1]** "Can you change the 10 sec delay on file change" (2013–2014; snapshot 2025-08-08): https://forum.resilio.com/topic/21784-can-you-change-the-10-sec-delay-on-file-change/ · https://web.archive.org/web/20250808224515/https://forum.resilio.com/topic/21784-can-you-change-the-10-sec-delay-on-file-change/
- **[F2]** "Make Bittorrent Start Syncing Faster" (2014; GreatMarko on `folder_rescan_interval`; snapshot 2025-08-15): https://web.archive.org/web/20250815124220/https://forum.resilio.com/topic/26769-make-bittorrent-start-syncing-faster/
- **[F3]** "Avoid can't sync xxxx errors while compiling" (2018; FileDelayConfig covers only listed extensions; snapshot 2025-08-09): https://web.archive.org/web/20250809190245/https://forum.resilio.com/topic/44713-avoid-cant-sync-xxxx-errors-while-compiling/

**Docker**

- **[D1]** Docker docs: WSL 2 best practices: https://docs.docker.com/desktop/features/wsl/best-practices/
- **[D2]** Docker docs: Host network driver (Docker Desktop section): https://docs.docker.com/engine/network/drivers/host/
- **[D3]** Docker docs: Docker Desktop networking overview: https://docs.docker.com/desktop/features/networking/
- **[D4]** Docker docs: Networking how-tos (`host.docker.internal`): https://docs.docker.com/desktop/features/networking/networking-how-tos/

**Microsoft**

- **[M1]** Microsoft Learn: Accessing network applications with WSL (updated 2026-06-02): https://learn.microsoft.com/en-us/windows/wsl/networking
- **[M2]** Microsoft Learn: Working across file systems (updated 2026-06-02): https://learn.microsoft.com/en-us/windows/wsl/filesystems
- **[M3]** Microsoft Learn: ReadDirectoryChangesW (updated 2025-07-01): https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw

**Alternatives**

- **[A1]** Syncthing configuration reference (`fsWatcherDelayS`, `fsWatcherTimeoutS`): https://docs.syncthing.net/users/config.html
- **[A2]** Mutagen documentation: Watching: https://mutagen.io/documentation/synchronization/watching

**Local evidence**

- **[L1]** Local evidence, 2026-10-04:
  - Windows peer storage folder `C:\Users\<user>\AppData\Roaming\Resilio Sync\`: `sync.log`, debug lines 12:10:54–12:18:28 local time, plus `debug.txt` and `FileDelayConfig`.
  - `docker logs resilio-sync` after the 05:25 UTC restart.
  - Read-only. `data/` wasn't read.
