# homesick-diskcare

Disk-space maintenance tooling, managed as a [homesick](https://github.com/technicalpickles/homesick) castle.

Two independent pieces, both running as **systemd user timers** (no root, survive logout via `loginctl enable-linger`):

| Tool | What it does | Schedule |
|---|---|---|
| `cache-cleanup.sh` | Deletes **regenerable** tool caches older than 14 days (JetBrains, uv, npm, Homebrew, Playwright, pip, composer), vacuums the user journal, empties aged Trash. | Weekly, Sun 03:00 |
| `disk-monitor.sh` | **Read-only.** Sends a desktop notification when `/` crosses 85% (warn) / 92% (critical). Never deletes anything. | Hourly |

## Safety design

- `cache-cleanup.sh` has a hard whitelist: it refuses any path outside `~/.cache` and `~/.npm/_cacache`. It **never** touches DB dumps (`*.sql*`), project source, `vendor/`, `node_modules/`, or git worktrees.
- Deletions are age-gated (default 14 days) so an actively-used cache is never removed mid-build.
- `disk-monitor.sh` only measures and notifies — it has no delete path at all.
- Both run at idle I/O priority and cap every external call with `timeout`, so they can't hang or disrupt work.

## Install on a new machine

```bash
homesick clone revagomes/homesick-diskcare
homesick symlink diskcare

# systemd doesn't auto-reload or enable timers — do it once:
systemctl --user daemon-reload
systemctl --user enable --now cache-cleanup.timer disk-monitor.timer

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

# Force a status notification (for testing):
disk-monitor.sh --force

# Check schedule / read logs:
systemctl --user list-timers
tail -f ~/.local/state/cache-cleanup/cache-cleanup.log
tail -f ~/.local/state/disk-monitor/disk-monitor.log
```

## Tunables (environment variables)

| Variable | Default | Applies to |
|---|---|---|
| `CACHE_CLEANUP_MAX_AGE_DAYS` | `14` | cache-cleanup |
| `CACHE_CLEANUP_JOURNAL_CAP` | `200M` | cache-cleanup |
| `DISK_MONITOR_MOUNT` | `/` | disk-monitor |
| `DISK_MONITOR_WARN_PCT` | `85` | disk-monitor |
| `DISK_MONITOR_CRIT_PCT` | `92` | disk-monitor |

## Notes

- Runtime state lives in `~/.local/state/{cache-cleanup,disk-monitor}/` and is **not** part of this castle (created at runtime).
- GNOME notifications only render `<b>`/`<i>` markup — not `<tt>` or font-size tags — so bodies use bold + spacing only.
