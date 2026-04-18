# ReBalance — Unraid Array Disk Usage Balancer

Custom Unraid plugin that moves files between array disks to equalise usage
percentage across mixed-capacity drives (e.g. 3.6 TB and 1.8 TB drives in the
same array). Targets a weighted average usage % so every disk lands at
roughly the same fill level rather than the same raw byte count.

---

## Project structure

```
ReBalance/
├── CLAUDE.md                        ← this file
├── rebalance.plg                    ← Unraid plugin manifest (XML)
├── rebalance.tar.gz                 ← built package (output of package.sh)
├── package.sh                       ← build script (run via WSL)
└── plugin/
    ├── ReBalance.page               ← Unraid page file: PHP + HTML/CSS/JS UI
    └── scripts/
        ├── rebalance.sh             ← bash backend (disk scan, plan, execute)
        ├── status.php               ← PHP AJAX endpoint (start/stop/status)
        └── images/
            └── rebalance.svg        ← plugin icon
```

Installed on Unraid at:
```
/usr/local/emhttp/plugins/rebalance/
```

UI accessible at: **Tools → ReBalance**

---

## How to build and deploy

Build requires Linux/WSL (uses `tar` with `--transform`).

```bash
# From WSL:
cd /mnt/c/Users/steve/OneDrive/Documents/Scripts/ReBalance
bash package.sh
```

Outputs `rebalance.tar.gz` in the project root (`.plg` is already there).

**Deploy to Unraid (SSH):**
```bash
mkdir -p /boot/config/plugins/rebalance
cp rebalance.plg     /boot/config/plugins/rebalance/
cp rebalance.tar.gz  /boot/config/plugins/rebalance/
```

Then in the Unraid web UI: **Plugins → Install Plugin**, browse to
`/boot/config/plugins/rebalance/rebalance.plg`.

Note: Unraid's Community Applications pre-hook logs
`"Cannot install rebalance.tar.gz: invalid package extension"` — this is
harmless and the plugin installs correctly regardless.

---

## Architecture

### rebalance.sh
Pure bash, runs as a background daemon launched by PHP.

Key flow:
1. Writes PID to `/tmp/rebalance.lock` (singleton guard)
2. Writes initial `state=starting` to `/tmp/rebalance_status.json` immediately
   (so the PHP poller never sees a "running but no status" window)
3. `discover_disks` — scans `/mnt/disk[0-9]*`, reads `df` stats
4. `calc_target` — computes weighted average usage % across all disks
5. `build_plan` — identifies source disks (above target+tolerance), scans
   files largest-first, assigns each file to the best destination disk,
   updates virtual disk state as files are planned. Emits
   `planning_disk_index` / `planning_disk_count` so the UI can show a
   deterministic progress bar.
6. If `--dry-run`: exits with `STATE=planned`, no files moved
7. If nothing to do: exits with `STATE=completed`
8. `execute_plan` / `execute_plan_cached` — moves files via `rsync -aX`,
   updates stats, writes status every 5 seconds
9. `_on_exit` trap — sets final state, writes status, cleans staging dir,
   removes lock file

Status is written atomically via `mktemp` + `mv` to avoid partial reads.

**Cache-assisted mode** (`--use-cache`): while file N is being rsync'd to its
destination (slow parity write), file N+1 is pre-staged from source to the
SSD cache in the background. Gives ~1.5× throughput by overlapping source
reads with destination writes on separate physical devices.

**Min file size filter** (`--min-file-kb N`): `find` uses `-size +Nk` to skip
small files (subtitles, NFOs, thumbnails). Passed from the UI's "Minimum File
Size" field (in MB, converted to KB before sending).

### status.php
Thin PHP AJAX endpoint. No framework.

- **GET** `/plugins/rebalance/scripts/status.php?tolerance=N`
  - If script running + status file exists → return status file verbatim
  - If script running + no status file yet → return synthetic `state=starting`
    (prevents poller from stopping prematurely during startup)
  - If not running → return `idle_payload()` which overlays the last run's
    results (plan, log, stats) from the status file onto fresh live disk data
  - Response always includes `cache_pools` array (detected from `disks.ini`)
- **POST** actions: `start`, `stop`, `clear`
  - All POST requests **must include `csrf_token`** — Unraid's emhttp silently
    drops POSTs without it (returns HTTP 200 with empty body)
  - `launch_script()` uses `exec()` with `nohup ... </dev/null >/dev/null 2>&1 &`
    — stdin closed so child is fully detached from PHP-FPM worker.
    `proc_open` + `proc_close` was tried first but blocks until child exits.
  - `start` action accepts: `tolerance`, `dry_run`, `use_cache`,
    `cache_buffer_kb`, `stage_dir`, `min_file_kb`

Key defensive patterns:
- `ob_start()` at top of file captures any stray output (BOM, warnings)
- `json_out()` calls `ob_clean()` before every `echo json_encode()` so stray
  buffered content never corrupts the JSON response
- `catch (Throwable $e)` wrapper ensures all PHP errors return valid JSON

### ReBalance.page
Unraid `.page` file format: PHP frontmatter + HTML/CSS/JS in one file.
Served by Unraid's emhttp web server.

PHP section reads the CSRF token:
```php
$var  = @parse_ini_file('/var/local/emhttp/var.ini') ?: [];
$csrf = $var['csrf_token'] ?? '';
```

The token is injected into JS as `var CSRF_TOKEN = '...'` and appended to
every POST body as `csrf_token`.

JS polling: `setInterval(poll, 2000)` while state is `running/planning/starting`.
Stops automatically when a terminal state (`completed/planned/stopped/error`)
is reached.

**Inline progress bar** (right of Stop button):
- `starting` → animated blue sweep (indeterminate)
- `planning` (before first disk data) → animated blue sweep (indeterminate)
- `planning` (once `planning_disk_index` > 0) → **deterministic** solid blue bar,
  fills one step per source disk completed. Label shows:
  `Disk 3 of 6  —  593,484 files / 748.9 GB planned  (~12 min left)…`
  ETA is calculated as `elapsed ÷ disks_done × disks_remaining` (shown once
  2+ disks have been processed).
- `running` → solid green, fills to `stats.pct_done` %
- `completed` → full green, "100%"
- `planned` (dry-run done) → full green, "Ready"
- `stopped` → orange, frozen at % reached
- `error` → full red, "Error"

**Buttons:**
- "Analyze (Plan Only)" — always forces dry-run regardless of the Dry Run checkbox
- "Start Rebalance" — respects the Dry Run checkbox

**Minimum File Size filter** — editable number field (in MB) on the same line
as the Dark Mode toggle. Default 0 (no filter). Skips files smaller than the
specified size during planning and execution. Useful for excluding small media
sidecar files (subtitles, NFOs, thumbnails) from the plan to reduce file count
and focus moves on content that matters.

**Cache pool staging directory** — dropdown auto-populated from `cache_pools`
returned by the GET response (detected from `/var/local/emhttp/disks.ini`).
User's cache pool is `/mnt/ssd_cache`, not the default `/mnt/cache`.

Dark mode is toggled via `.rb-dark` CSS class on `#rebalance-wrap` and
persisted to `localStorage`.

---

## Key bugs fixed during development

### 1. CSRF token (root cause of all early POST failures)
Unraid's emhttp validates `csrf_token` on all POST requests to plugin PHP
files. Missing token → HTTP 200 with **empty body** (no error, silent drop).
Syslog entry: `webGUI: E plugins/rebalance/scripts/status.php - missing csrf_token`.
Fix: read token from `/var/local/emhttp/var.ini`, inject into JS, send with
every POST.

### 2. proc_open blocks PHP response
`proc_open()` + `proc_close()` waits for the child process to exit before
returning. For a multi-hour rebalance this would hold the HTTP connection open
indefinitely. Fix: use `exec('nohup cmd </dev/null >/dev/null 2>&1 &')` which
returns immediately.

### 3. Poller race condition (script alive but no status file yet)
Between the script writing its lock file and its first `write_status()` call,
the PHP GET handler would fall through to `idle_payload()` → JS received
`state=idle` → poller stopped → results never displayed.
Two-part fix:
- bash: call `write_status` immediately after writing the lock file
- PHP: if `is_running()` but no status file, return synthetic `state=starting`
  so the poller keeps going

### 4. Empty JSON responses (ob_start / stray output)
Any PHP output before `header()` or `echo json_encode()` corrupts the JSON.
Fix: `ob_start()` at file top, `ob_clean()` inside `json_out()` before every
echo.

### 5. Wrong staging directory (hardcoded /mnt/cache)
The staging path was hardcoded to `/mnt/cache/.rebalance_stage`. User's cache
pool is named `ssd_cache`, mounted at `/mnt/ssd_cache`. Fix: `detect_cache_pools()`
in PHP reads `/var/local/emhttp/disks.ini` to find the actual cache pool name;
bash does the same with `awk`. A `--stage-dir` override is also supported.

### 6. Planning took hours (find | sort pipeline)
`find … | sort -k1,1rn` sorted the entire file list before the while-loop
could start processing. On 3.6 TB disks with hundreds of thousands of files
this caused multi-hour delays before any plan entries appeared.
Fix: removed `sort` entirely. Files are processed in find's natural order;
the planner still picks the largest file it can that fits a destination, so
the result is near-optimal without the sort bottleneck.

### 7. Min file size filter never applied (size_opt placement)
`local size_opt=""` and its assignment were inside the while loop body, just
before `done < <(find ... ${size_opt} ...)`. Bash evaluates the process
substitution (and expands `${size_opt}`) when the while loop's input
redirection is set up — before the first iteration runs — so `size_opt` was
always empty and `-size +Nk` was never passed to `find`.
Fix: moved both lines to before the `while` statement.

### 8. Duplicate START_TIME declaration
When adding the early `write_status` call (bug #3 fix), `START_TIME=$(date +%s)`
was accidentally duplicated. Caused elapsed time to reset mid-run.
Fix: removed the duplicate assignment.

---

## Status JSON fields (written by rebalance.sh)

Key fields relevant to the UI:

| Field | Type | Notes |
|---|---|---|
| `state` | string | `starting` / `planning` / `running` / `planned` / `completed` / `stopped` / `error` |
| `dry_run` | bool | true if `--dry-run` was passed |
| `use_cache` | bool | true if cache-assisted mode |
| `tolerance` | int | ±% tolerance around target |
| `target_pct` | int | weighted average usage % |
| `elapsed_sec` | int | seconds since script started |
| `planning_disk_index` | int | which source disk is currently being scanned (1-based) |
| `planning_disk_count` | int | total number of source disks to scan |
| `plan_count` | int | number of file moves planned so far |
| `stats.files_total` | int | same as plan_count after planning |
| `stats.bytes_total_kb` | int | total KB to move |
| `stats.pct_done` | int | execution progress % |
| `disks` | array | per-disk name/size/used/free/pct/role |
| `plan` | array | first 300 planned moves (status/kb/src/dst) |
| `log` | array | last 100 log entries ({t, m}) |
| `cache_pools` | array | only in idle GET response; detected cache pools |

---

## Unraid-specific notes

- **Plugin files** land in `/usr/local/emhttp/plugins/rebalance/` — wiped on
  every reinstall, not persisted across reboots. Runtime state (`/tmp/`) is
  also lost on reboot.
- **Boot persistence**: the `.plg` and `.tar.gz` live on the USB boot drive at
  `/boot/config/plugins/rebalance/`. Unraid reinstalls the plugin on every
  boot from there.
- **PHP environment**: lighttpd + PHP-FPM. `exec()` and `shell_exec()` are
  available. `proc_open` is available but blocks on `proc_close`.
- **Disk paths**: array data disks mount at `/mnt/disk1`, `/mnt/disk2`, etc.
  Cache pool at `/mnt/ssd_cache` (user-specific; detected at runtime).
  The script discovers disks via `ls -dv /mnt/disk[0-9]*`.
- **File system**: XFS on all array disks. `rsync -aX` preserves extended
  attributes. XFS fragmentation is not a concern for this workload.
- **Parity**: Unraid updates parity on every write. File moves trigger parity
  writes on both source and destination disks — normal and expected.
- **Page menu location**: `Menu="Utilities"` in the `.page` frontmatter puts
  the plugin under **Tools** in the Unraid nav.
- **Community Applications**: The plugin is not yet submitted to CA. It shows
  a warning "not known to Community Applications" — harmless. To submit:
  host on GitHub, update `pluginURL` in `.plg` to the raw GitHub URL, create
  a support thread on the Unraid forums, then submit a PR to the CA repository.

---

## User's array (reference)

- Mix of 3.6 TB disks (disk1–disk13) and 1.8 TB disks (disk14–disk20)
- As of 2026-04-16: 3.6 TB disks at 66–77%, 1.8 TB disks at 13–54%
- Target ~54% weighted average, tolerance ±2%
- Source disks (needing reduction): disk2–disk7 (6 disks, all 3.6 TB)
- Dry-run result (2026-04-17): ~700k+ files / ~900 GB to move across 6 source disks
  - Many small files (avg ~1.3 MB) — subtitles, NFOs, thumbnails
  - Recommend using Min File Size filter (e.g. 100 MB) for the real run to
    focus moves on content files and reduce total file count dramatically
- SSD cache pool name: `ssd_cache`, mounted at `/mnt/ssd_cache`
- Cache-assisted mode available and tested (improves throughput ~1.5×)
- All disks formatted XFS
- Real run not yet attempted as of 2026-04-17

---

## Potential future improvements

- Scheduler: run rebalance automatically on a cron schedule
- Per-share exclusions: skip specific shares (e.g. `appdata`, `system`)
- Email/notification on completion
- Resume across reboots: persist plan to `/boot/config/plugins/rebalance/`
- Rate limiting: cap transfer speed to leave headroom for other workloads
- Multi-pass planning: re-evaluate target after each source disk is drained
- Community Applications submission (see Unraid-specific notes above)
