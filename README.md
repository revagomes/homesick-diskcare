# homesick-diskcare

Disk-space maintenance tooling, managed as a [homesick](https://github.com/technicalpickles/homesick) castle.

Two independent pieces, both running as **systemd user timers** (no root, survive logout via `loginctl enable-linger`):

| Tool | What it does | Schedule |
|---|---|---|
| `cache-cleanup.sh` | Deletes **regenerable** tool caches older than 14 days (JetBrains, uv, npm, Homebrew, Playwright, pip, composer), vacuums the user journal, empties aged Trash. | Weekly, Sun 03:00 |
| `disk-monitor.sh` | **Read-only.** Sends a desktop notification when `/` crosses 85% (warn) / 92% (critical). Never deletes anything. | Hourly |
| `mem-monitor.sh` | **Read-only.** Notifies on low MemAvailable, high swap, swap-in thrashing, PSI memory pressure, and OOM kills. Never kills a process or drops caches. | Every 15 min |

## Safety design

- `cache-cleanup.sh` has a hard whitelist: it refuses any path outside `~/.cache` and `~/.npm/_cacache`. It **never** touches DB dumps (`*.sql*`), project source, `vendor/`, `node_modules/`, or git worktrees.
- Deletions are age-gated (default 14 days) so an actively-used cache is never removed mid-build.
- `disk-monitor.sh` only measures and notifies — it has no delete path at all.
- `mem-monitor.sh` is read-only too: it **never** kills a process and **never** writes `/proc/sys/vm/drop_caches`. It only measures and notifies.
- Both run at idle I/O priority and cap every external call with `timeout`, so they can't hang or disrupt work.

## Install on a new machine

```bash
homesick clone revagomes/homesick-diskcare
homesick symlink diskcare

# systemd doesn't auto-reload or enable timers — do it once:
systemctl --user daemon-reload
systemctl --user enable --now cache-cleanup.timer disk-monitor.timer mem-monitor.timer

# (optional) run even when logged out:
loginctl enable-linger "$USER"
```

## Usage

```bash
# Preview what cleanup would remove, delete nothing:
cache-cleanup.sh --dry-run

# Run either now:
systemctl --user start cache-cleanup.service
systemctl --user start disk-monitor.service
systemctl --user start mem-monitor.service

# Force a status notification (for testing):
disk-monitor.sh --force
mem-monitor.sh --force

# Check schedule / read logs:
systemctl --user list-timers
tail -f ~/.local/state/cache-cleanup/cache-cleanup.log
tail -f ~/.local/state/disk-monitor/disk-monitor.log
tail -f ~/.local/state/mem-monitor/mem-monitor.log
```

## Tunables (environment variables)

| Variable | Default | Applies to |
|---|---|---|
| `CACHE_CLEANUP_MAX_AGE_DAYS` | `14` | cache-cleanup |
| `CACHE_CLEANUP_JOURNAL_CAP` | `200M` | cache-cleanup |
| `DISK_MONITOR_MOUNT` | `/` | disk-monitor |
| `DISK_MONITOR_WARN_PCT` | `85` | disk-monitor |
| `DISK_MONITOR_CRIT_PCT` | `92` | disk-monitor |
| `MEM_MONITOR_WARN_AVAIL_MB` | `1536` | mem-monitor (warn under this MemAvailable) |
| `MEM_MONITOR_CRIT_AVAIL_MB` | `768` | mem-monitor (crit under this MemAvailable) |
| `MEM_MONITOR_WARN_SWAP_PCT` | `50` | mem-monitor |
| `MEM_MONITOR_CRIT_SWAP_PCT` | `80` | mem-monitor |
| `MEM_MONITOR_WARN_PSI` | `10` | mem-monitor (PSI memory "some avg60" %) |
| `MEM_MONITOR_CRIT_PSI` | `40` | mem-monitor |
| `MEM_MONITOR_CHURN_PAGES_WARN` | `262144` | mem-monitor (swap-in pages/run ≈ 1 GiB) |

## Notes

- Runtime state lives in `~/.local/state/{cache-cleanup,disk-monitor,mem-monitor}/` and is **not** part of this castle (created at runtime).
- GNOME notifications only render `<b>`/`<i>` markup — not `<tt>` or font-size tags — so bodies use bold + spacing only.
