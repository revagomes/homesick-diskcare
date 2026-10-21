#!/usr/bin/env bash
#
# docker-report.sh — report Docker disk usage and warn about reclaimable bloat.
#
# Read-only: this script NEVER prunes, removes, or deletes anything. Docker
# cleanup (especially volumes) needs human judgement — named volumes routinely
# hold live databases — so this is a *reporter*, the Docker-aware companion to
# disk-monitor.sh. It only measures and notifies.
#
# It exists because disk-monitor.sh / cache-cleanup.sh are blind to
# /var/lib/docker, which is root-owned and invisible to unprivileged `du`.
# Docker growth there is a common cause of a full root filesystem.
#
# Thresholds:
#   RECLAIM_WARN_G   (default 20) -> total reclaimable space that triggers a hint
#   VOLUME_WARN_G    (default 25) -> a single volume this large is flagged
#
# Usage:
#   docker-report.sh           # check and notify if something looks reclaimable
#   docker-report.sh --force   # always notify current status (for testing)
#
set -uo pipefail

RECLAIM_WARN_G="${DOCKER_REPORT_RECLAIM_WARN_G:-20}"
VOLUME_WARN_G="${DOCKER_REPORT_VOLUME_WARN_G:-25}"
HOME_DIR="${HOME:-/home/vascore}"
LOG_DIR="$HOME_DIR/.local/state/docker-report"
LOG_FILE="$LOG_DIR/docker-report.log"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

# A user systemd timer does not inherit the graphical session environment, so
# discover DISPLAY and the dbus session bus from the running GNOME session.
setup_gui_env() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${DISPLAY:-}" ] && return 0
  local uid; uid="$(id -u)"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] \
    && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  if [ -z "${DISPLAY:-}" ]; then
    local d
    d="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
    if [ -z "$d" ]; then
      local sock
      sock="$(ls /tmp/.X11-unix/X* 2>/dev/null | sort | head -1)"
      [ -n "$sock" ] && d=":${sock##*/X}"
    fi
    [ -n "$d" ] && export DISPLAY="$d"
  fi
}

notify() {
  local urgency="$1" title="$2" body="$3"
  setup_gui_env
  if command -v notify-send >/dev/null 2>&1; then
    timeout 10 notify-send --app-name="Docker Report" --urgency="$urgency" \
      --icon=drive-harddisk "$title" "$body" 2>/dev/null \
      && log "notified ($urgency): $title" \
      || log "notify-send failed/timed out ($urgency): $title"
  else
    log "notify-send unavailable; wanted ($urgency): $title — $body"
  fi
}

# Docker must be reachable without sudo (user in the 'docker' group).
if ! command -v docker >/dev/null 2>&1; then
  log "docker not installed; nothing to report"
  exit 0
fi
if ! docker ps >/dev/null 2>&1; then
  log "docker daemon not reachable without sudo; skipping (add user to 'docker' group)"
  exit 0
fi

# Convert a docker size string (e.g. "70.19GB", "356.5kB", "5.08GB") to integer GB.
# Rounds down; sub-GB values become 0.
to_gb() {
  awk -v s="$1" 'BEGIN{
    n=s; sub(/[A-Za-z]+$/,"",n)+0; unit=s; sub(/^[0-9.]+/,"",unit);
    v=n+0;
    if (unit=="TB") v=v*1024;
    else if (unit=="GB") v=v;
    else if (unit=="MB") v=v/1024;
    else if (unit=="kB"||unit=="KB") v=v/1048576;
    else if (unit=="B") v=v/1073741824;
    printf "%d", v;
  }'
}

# --- Totals from `docker system df` -----------------------------------------
# Machine-friendly; columns: Type, Total, Active, Size, Reclaimable
DF_RAW="$(docker system df 2>/dev/null)"
log "system df:"; printf '%s\n' "$DF_RAW" | sed 's/^/    /' >> "$LOG_FILE"

# Sum reclaimable across all rows (strip the "(NN%)" suffix).
RECLAIM_TOTAL_G=0
while IFS= read -r line; do
  # Reclaimable is the last whitespace-separated field before an optional "(..%)".
  rec="$(printf '%s' "$line" | sed -nE 's/.*[[:space:]]([0-9.]+[A-Za-z]+)[[:space:]]*\([0-9]+%\)$/\1/p')"
  [ -z "$rec" ] && continue
  g="$(to_gb "$rec")"
  RECLAIM_TOTAL_G=$((RECLAIM_TOTAL_G + g))
done <<<"$DF_RAW"

# --- Largest UNUSED volumes (LINKS == 0) ------------------------------------
# docker system df -v lists per-volume: Name, Links, Size
UNUSED_HINT=""
BIG_UNUSED_G=0
DFV_RAW="$(docker system df -v 2>/dev/null)"
# Extract the "Local Volumes space usage" block.
VOL_BLOCK="$(printf '%s\n' "$DFV_RAW" | awk '/Local Volumes space usage:/{f=1;next} /space usage:/{if(f)exit} f')"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in VOLUME*NAME*|*LINKS*) continue;; esac
  name="$(printf '%s' "$line" | awk '{print $1}')"
  links="$(printf '%s' "$line" | awk '{print $2}')"
  size="$(printf '%s' "$line" | awk '{print $3}')"
  [ "$links" = "0" ] || continue
  g="$(to_gb "$size")"
  BIG_UNUSED_G=$((BIG_UNUSED_G + g))
  # Shorten long anonymous volume hashes for readability.
  short="$name"; [ "${#name}" -gt 28 ] && short="${name:0:25}…"
  UNUSED_HINT="$UNUSED_HINT   • $short\t$size\n"
done <<<"$VOL_BLOCK"

ROOT_PCT="$(df -BG --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
log "reclaimable total ~${RECLAIM_TOTAL_G}G, unused volumes ~${BIG_UNUSED_G}G, root ${ROOT_PCT:-?}% used"

SHOULD_NOTIFY=0
[ "$RECLAIM_TOTAL_G" -ge "$RECLAIM_WARN_G" ] && SHOULD_NOTIFY=1
[ "$BIG_UNUSED_G"    -ge "$VOLUME_WARN_G" ] && SHOULD_NOTIFY=1
[ "$FORCE" -eq 1 ] && SHOULD_NOTIFY=1

if [ "$SHOULD_NOTIFY" -eq 1 ]; then
  body="$(printf 'Root disk: <b>%s%%</b> used\nReclaimable (images/cache/unused vols): <b>~%sG</b>\n\n<b>Unused volumes (LINKS=0):</b>\n%s\nReview with  docker system df -v\nSafe reclaim:  docker image prune -a / docker builder prune -a\nVolumes: remove individually after checking they hold no live DB.' \
    "${ROOT_PCT:-?}" "$RECLAIM_TOTAL_G" "${UNUSED_HINT:-   • (none)\n}")"
  if [ "$RECLAIM_TOTAL_G" -ge "$RECLAIM_WARN_G" ] || [ "$BIG_UNUSED_G" -ge "$VOLUME_WARN_G" ]; then
    notify normal "Docker reclaimable space ~${RECLAIM_TOTAL_G}G" "$body"
  else
    notify low "Docker OK — ~${RECLAIM_TOTAL_G}G reclaimable" "$body"
  fi
fi

tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
exit 0
