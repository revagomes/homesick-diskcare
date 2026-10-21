#!/usr/bin/env bash
#
# disk-monitor.sh — alert (desktop notification) when disk space runs low.
#
# Read-only: this script NEVER deletes anything. It only measures and notifies.
# It is the "early warning" companion to cache-cleanup.sh, aimed at the things
# cleanup deliberately won't touch (DB dumps, large project trees).
#
# Thresholds (percent used of the monitored filesystem):
#   WARN_PCT  (default 85) -> normal-urgency notification
#   CRIT_PCT  (default 92) -> critical-urgency notification (stays on screen)
#
# Usage:
#   disk-monitor.sh           # check and notify if over threshold
#   disk-monitor.sh --force   # always notify current status (for testing)
#
set -uo pipefail

MOUNT="${DISK_MONITOR_MOUNT:-/}"
WARN_PCT="${DISK_MONITOR_WARN_PCT:-85}"
CRIT_PCT="${DISK_MONITOR_CRIT_PCT:-92}"
HOME_DIR="${HOME:-/home/vascore}"
LOG_DIR="$HOME_DIR/.local/state/disk-monitor"
LOG_FILE="$LOG_DIR/disk-monitor.log"
STATE_FILE="$LOG_DIR/last-level"   # remembers last alert level to avoid spam

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
  # Find DISPLAY if still unset. Prefer the systemd user environment (fast),
  # then fall back to active X sockets. Avoid scanning all of /proc.
  if [ -z "${DISPLAY:-}" ]; then
    local d
    d="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
    if [ -z "$d" ]; then
      # Pick the lowest-numbered X11 socket that exists, e.g. /tmp/.X11-unix/X1 -> :1
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
    # Hard 10s cap so a wedged dbus/notification daemon can never hang the run.
    timeout 10 notify-send --app-name="Disk Monitor" --urgency="$urgency" \
      --icon=drive-harddisk "$title" "$body" 2>/dev/null \
      && log "notified ($urgency): $title — $body" \
      || log "notify-send failed/timed out ($urgency): $title"
  else
    log "notify-send unavailable; wanted ($urgency): $title — $body"
  fi
}

# Collect usage figures for the monitored filesystem.
read -r PCT AVAIL_G <<<"$(df -BG --output=pcent,avail "$MOUNT" 2>/dev/null \
  | tail -1 | tr -dc '0-9 ' | awk '{print $1, $2}')"
PCT="${PCT:-0}"; AVAIL_G="${AVAIL_G:-0}"

# Identify the biggest offenders to make the alert actionable.
# Emits a newline-separated bulleted list (one "size  path" per line).
biggest_hint() {
  # Report the biggest consumers of the MONITORED filesystem ($MOUNT), not of
  # $HOME. On this host $HOME is a bind mount from a separate partition, so a
  # home-dir scan would mislead when the root disk ("/") is the one filling up.
  # Each `du -x` stays on one filesystem (does not cross mount points).
  #
  # Fast and shallow; never descends deeply. Capped so it can't stall the alert.
  local scan_root="$MOUNT"
  if [ "$MOUNT" = "/" ]; then
    # The usual root-disk offenders. /var/lib/docker is root-owned and invisible
    # to unprivileged du, so surface a docker-aware line when docker is usable.
    timeout 15 du -xh --max-depth=1 /usr /var /opt 2>/dev/null \
      | sort -rh | sed -n '1,3p' | awk '{printf "   • %s\t%s\n", $1, $2}'
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
      local dsz
      dsz="$(docker system df --format '{{.Type}} {{.Size}} ({{.Reclaimable}} reclaimable)' 2>/dev/null \
             | awk '/Volumes|Images/{print "   • docker " $0}')"
      [ -n "$dsz" ] && printf '%s\n' "$dsz"
    fi
  else
    timeout 20 du -xh --max-depth=1 "$scan_root" 2>/dev/null | sort -rh | sed -n '2,4p' \
      | awk '{printf "   • %s\t%s\n", $1, $2}'
  fi
}

LEVEL="ok"
[ "$PCT" -ge "$WARN_PCT" ] && LEVEL="warn"
[ "$PCT" -ge "$CRIT_PCT" ] && LEVEL="crit"

LAST="$(cat "$STATE_FILE" 2>/dev/null || echo ok)"
log "check: $MOUNT ${PCT}% used, ${AVAIL_G}G free (level=$LEVEL, last=$LAST, force=$FORCE)"

case "$LEVEL" in
  crit)
    notify critical "⚠  Disk critically full — ${PCT}% used" \
"$(printf 'Only <b>%sG</b> free on  %s\n\n<b>Largest on this filesystem:</b>\n%s\nRun  cache-cleanup.sh  or free space.' \
  "$AVAIL_G" "$MOUNT" "$(biggest_hint)")"
    ;;
  warn)
    # Only re-warn on transition into warn, or when forced, to avoid nagging.
    if [ "$LAST" = "ok" ] || [ "$FORCE" -eq 1 ]; then
      notify normal "Disk getting full — ${PCT}% used" \
"$(printf '<b>%sG</b> free on  %s\n\n<b>Largest on this filesystem:</b>\n%s\nConsider cleanup soon.' \
  "$AVAIL_G" "$MOUNT" "$(biggest_hint)")"
    fi
    ;;
  ok)
    [ "$FORCE" -eq 1 ] && notify normal "Disk OK — ${PCT}% used" \
"$(printf '<b>%sG</b> free on  %s' "$AVAIL_G" "$MOUNT")"
    ;;
esac

echo "$LEVEL" > "$STATE_FILE"
tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
exit 0
