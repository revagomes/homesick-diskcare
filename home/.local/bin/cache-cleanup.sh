#!/usr/bin/env bash
#
# cache-cleanup.sh — periodic, SAFE reclamation of regenerable cache space.
#
# What it does (and ONLY this):
#   - Clears tool caches that regenerate automatically (JetBrains, uv, npm,
#     Homebrew, Playwright, pip, composer).
#   - Age-gates deletions: only files older than $MAX_AGE_DAYS are removed, so a
#     cache you are actively using mid-build is left alone.
#   - Vacuums the user systemd journal to a size cap (user journals only).
#   - Empties the XDG Trash of items older than $MAX_AGE_DAYS.
#
# What it DELIBERATELY never touches:
#   - Any *.sql / *.sql.gz / database dumps anywhere.
#   - Project source trees, vendor/, node_modules/ inside projects, git worktrees.
#   - Anything requiring human judgement.
#
# Usage:
#   cache-cleanup.sh            # perform cleanup
#   cache-cleanup.sh --dry-run  # show what WOULD be removed, delete nothing
#
set -uo pipefail

MAX_AGE_DAYS="${CACHE_CLEANUP_MAX_AGE_DAYS:-14}"
JOURNAL_CAP="${CACHE_CLEANUP_JOURNAL_CAP:-200M}"
HOME_DIR="${HOME:-/home/vascore}"
LOG_DIR="$HOME_DIR/.local/state/cache-cleanup"
LOG_FILE="$LOG_DIR/cache-cleanup.log"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

# Run heavy IO at lowest priority so normal work is unaffected.
LOWPRIO=(nice -n 19)
command -v ionice >/dev/null 2>&1 && LOWPRIO=(ionice -c3 nice -n 19)

disk_free() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'; }

# Remove cache contents older than MAX_AGE_DAYS. Never follows outside the dir.
# $1 = directory to prune
prune_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  # Safety: refuse to operate on anything that is not under a known cache root.
  case "$dir" in
    "$HOME_DIR"/.cache/*|"$HOME_DIR"/.npm/_cacache*) : ;;
    *) log "SKIP (not a whitelisted cache path): $dir"; return 0 ;;
  esac
  local count
  count=$(find "$dir" -mindepth 1 -mtime +"$MAX_AGE_DAYS" 2>/dev/null | wc -l)
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would prune $count item(s) older than ${MAX_AGE_DAYS}d from $dir"
    return 0
  fi
  if [ "$count" -gt 0 ]; then
    "${LOWPRIO[@]}" find "$dir" -mindepth 1 -mtime +"$MAX_AGE_DAYS" -delete 2>/dev/null
    log "pruned ~$count item(s) older than ${MAX_AGE_DAYS}d from $dir"
  else
    log "nothing older than ${MAX_AGE_DAYS}d in $dir"
  fi
}

log "=== cache-cleanup start (dry_run=$DRY_RUN, max_age=${MAX_AGE_DAYS}d) ==="
BEFORE=$(disk_free)
log "root free before: ${BEFORE}G"

# 1) Age-gated cache directories.
prune_dir "$HOME_DIR/.cache/JetBrains"
prune_dir "$HOME_DIR/.cache/uv"
prune_dir "$HOME_DIR/.cache/Homebrew"
prune_dir "$HOME_DIR/.cache/ms-playwright"
prune_dir "$HOME_DIR/.cache/pip"
prune_dir "$HOME_DIR/.cache/composer"
prune_dir "$HOME_DIR/.npm/_cacache"

# 2) Tool-native cache cleaners (respect each tool's own safety logic).
if [ "$DRY_RUN" -eq 0 ]; then
  command -v uv   >/dev/null 2>&1 && "${LOWPRIO[@]}" uv cache prune       >/dev/null 2>&1 && log "uv cache prune done"
  command -v npm  >/dev/null 2>&1 && "${LOWPRIO[@]}" npm cache verify     >/dev/null 2>&1 && log "npm cache verify done"
  command -v brew >/dev/null 2>&1 && "${LOWPRIO[@]}" brew cleanup --prune="$MAX_AGE_DAYS" >/dev/null 2>&1 && log "brew cleanup done"
else
  log "DRY-RUN would run: uv cache prune / npm cache verify / brew cleanup --prune=$MAX_AGE_DAYS"
fi

# 3) User journal vacuum (user journals only; no root needed).
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN would run: journalctl --user --vacuum-size=$JOURNAL_CAP"
else
  if journalctl --user --vacuum-size="$JOURNAL_CAP" >/dev/null 2>&1; then
    log "user journal vacuumed to $JOURNAL_CAP"
  fi
fi

# 4) XDG Trash, age-gated.
TRASH="$HOME_DIR/.local/share/Trash"
if [ -d "$TRASH" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    tc=$(find "$TRASH/files" "$TRASH/info" -mindepth 1 -mtime +"$MAX_AGE_DAYS" 2>/dev/null | wc -l)
    log "DRY-RUN would empty $tc trashed item(s) older than ${MAX_AGE_DAYS}d"
  else
    "${LOWPRIO[@]}" find "$TRASH/files" "$TRASH/info" -mindepth 1 -mtime +"$MAX_AGE_DAYS" -delete 2>/dev/null
    log "trash older than ${MAX_AGE_DAYS}d emptied"
  fi
fi

AFTER=$(disk_free)
log "root free after: ${AFTER}G (delta: $((AFTER - BEFORE))G)"
log "=== cache-cleanup end ==="

# Keep the log from growing unbounded.
tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
exit 0
