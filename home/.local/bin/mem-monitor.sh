#!/usr/bin/env bash
#
# mem-monitor.sh — alert (desktop notification) when memory runs low or the
# system is under memory PRESSURE.
#
# Read-only: this script NEVER kills a process and NEVER writes to
# /proc/sys/vm/drop_caches. It only measures and notifies — the read-only
# companion to disk-monitor.sh, for RAM/swap instead of disk.
#
# It looks at four signals, because "free RAM" alone is misleading on Linux:
#   1. MemAvailable (/proc/meminfo) — the kernel's own estimate of what a new
#      workload could get without swapping. The correct metric; NOT free-column
#      arithmetic, which ignores reclaimable cache.
#   2. Swap used %            — how much has spilled to swap.
#   3. Swap-in CHURN          — pages swapped IN since the last run (/proc/vmstat
#      pswpin). Sustained swap-in is thrashing even when MemAvailable looks ok.
#   4. PSI memory pressure    — /proc/pressure/memory "some avg60": the % of the
#      last 60s that tasks stalled waiting on memory. Best early-warning signal.
#
# It also reports OOM kills that happened since the last run (post-mortem), and
# lists the top RAM consumers so the alert is actionable.
#
# Thresholds (override via environment, see below):
#   WARN  -> normal-urgency notification
#   CRIT  -> critical-urgency notification (stays on screen)
#
# Usage:
#   mem-monitor.sh            # check and notify if over threshold
#   mem-monitor.sh --force    # always notify current status (for testing)
#
set -uo pipefail

# --- thresholds (all overridable) -------------------------------------------
# MemAvailable floors, in MiB.
WARN_AVAIL_MB="${MEM_MONITOR_WARN_AVAIL_MB:-1536}"   # warn under 1.5 GiB
CRIT_AVAIL_MB="${MEM_MONITOR_CRIT_AVAIL_MB:-768}"    # crit under 0.75 GiB
# Swap used %.
WARN_SWAP_PCT="${MEM_MONITOR_WARN_SWAP_PCT:-50}"
CRIT_SWAP_PCT="${MEM_MONITOR_CRIT_SWAP_PCT:-80}"
# PSI memory "some avg60" %.
WARN_PSI="${MEM_MONITOR_WARN_PSI:-10}"
CRIT_PSI="${MEM_MONITOR_CRIT_PSI:-40}"
# Swap-in churn: pages swapped IN since last run that counts as "thrashing".
# 1 page = 4 KiB, so 262144 pages ~= 1 GiB swapped in between runs.
CHURN_PAGES_WARN="${MEM_MONITOR_CHURN_PAGES_WARN:-262144}"

HOME_DIR="${HOME:-/home/vascore}"
LOG_DIR="$HOME_DIR/.local/state/mem-monitor"
LOG_FILE="$LOG_DIR/mem-monitor.log"
STATE_FILE="$LOG_DIR/last-level"        # anti-spam: last alert level
PSWPIN_FILE="$LOG_DIR/last-pswpin"      # for swap-in churn delta
OOM_STAMP_FILE="$LOG_DIR/last-oom-check" # for "OOM since last run"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

# A user systemd timer does not inherit the graphical session environment, so
# discover DISPLAY and the dbus session bus from the running session.
# (Identical approach to disk-monitor.sh — kept in sync deliberately.)
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
    # Hard 10s cap so a wedged dbus/notification daemon can never hang the run.
    timeout 10 notify-send --app-name="Memory Monitor" --urgency="$urgency" \
      --icon=utilities-system-monitor "$title" "$body" 2>/dev/null \
      && log "notified ($urgency): $title" \
      || log "notify-send failed/timed out ($urgency): $title"
  else
    log "notify-send unavailable; wanted ($urgency): $title"
  fi
}

# --- collect metrics ---------------------------------------------------------
# MemAvailable + swap totals from /proc/meminfo (values are in KiB).
MEM_AVAIL_MB=0 SWAP_TOTAL_MB=0 SWAP_FREE_MB=0
while read -r key val _; do
  case "$key" in
    MemAvailable:) MEM_AVAIL_MB=$(( val / 1024 )) ;;
    SwapTotal:)    SWAP_TOTAL_MB=$(( val / 1024 )) ;;
    SwapFree:)     SWAP_FREE_MB=$(( val / 1024 )) ;;
  esac
done < /proc/meminfo

SWAP_USED_MB=$(( SWAP_TOTAL_MB - SWAP_FREE_MB ))
if [ "$SWAP_TOTAL_MB" -gt 0 ]; then
  SWAP_PCT=$(( SWAP_USED_MB * 100 / SWAP_TOTAL_MB ))
else
  SWAP_PCT=0
fi

# PSI memory pressure: "some avg60". Absent on kernels without CONFIG_PSI.
PSI=0
if [ -r /proc/pressure/memory ]; then
  PSI="$(awk '/^some/{for(i=1;i<=NF;i++){if($i ~ /^avg60=/){split($i,a,"=");printf "%d", a[2]}}}' \
    /proc/pressure/memory 2>/dev/null)"
  PSI="${PSI:-0}"
fi

# Swap-in churn since last run: delta of /proc/vmstat pswpin.
PSWPIN_NOW="$(awk '/^pswpin /{print $2}' /proc/vmstat 2>/dev/null)"
PSWPIN_NOW="${PSWPIN_NOW:-0}"
PSWPIN_LAST="$(cat "$PSWPIN_FILE" 2>/dev/null || echo "$PSWPIN_NOW")"
# Guard against counter reset on reboot (now < last).
if [ "$PSWPIN_NOW" -ge "$PSWPIN_LAST" ]; then
  CHURN=$(( PSWPIN_NOW - PSWPIN_LAST ))
else
  CHURN=0
fi
echo "$PSWPIN_NOW" > "$PSWPIN_FILE"

# OOM kills since the last check (post-mortem signal). Bounded, best-effort.
OOM_HINT=""
if command -v journalctl >/dev/null 2>&1; then
  OOM_SINCE="$(cat "$OOM_STAMP_FILE" 2>/dev/null || echo '')"
  if [ -n "$OOM_SINCE" ]; then
    OOM_HINT="$(timeout 10 journalctl --user --since "$OOM_SINCE" -k 2>/dev/null \
      | grep -iE 'Out of memory|oom-kill|Killed process' | tail -3 || true)"
    # Also catch system-scope kernel oom lines if the user can read them.
    if [ -z "$OOM_HINT" ]; then
      OOM_HINT="$(timeout 10 journalctl --since "$OOM_SINCE" -k 2>/dev/null \
        | grep -iE 'Out of memory|oom-kill|Killed process' | tail -3 || true)"
    fi
  fi
fi
date '+%Y-%m-%d %H:%M:%S' > "$OOM_STAMP_FILE"

# Top RAM consumers, aggregated by command, for an actionable alert body.
top_consumers() {
  ps -eo rss,comm --sort=-rss 2>/dev/null \
    | awk 'NR>1{mb=$1/1024; agg[$2]+=mb} END{for(c in agg) printf "%.0f\t%s\n", agg[c], c}' \
    | sort -rn | sed -n '1,5p' \
    | awk '{printf "   • %s\t%d MB\n", $2, $1}'
}

# --- classify ----------------------------------------------------------------
LEVEL="ok"
REASONS=""
add_reason() { REASONS="${REASONS:+$REASONS, }$1"; }

# warn conditions
[ "$MEM_AVAIL_MB" -lt "$WARN_AVAIL_MB" ] && { LEVEL="warn"; add_reason "MemAvailable ${MEM_AVAIL_MB}MB"; }
[ "$SWAP_PCT"    -ge "$WARN_SWAP_PCT"   ] && { LEVEL="warn"; add_reason "swap ${SWAP_PCT}%"; }
[ "$PSI"         -ge "$WARN_PSI"        ] && { LEVEL="warn"; add_reason "PSI ${PSI}%"; }
[ "$CHURN"       -ge "$CHURN_PAGES_WARN" ] && { LEVEL="warn"; add_reason "swap-in churn $(( CHURN / 256 ))MB"; }

# crit conditions (override warn)
[ "$MEM_AVAIL_MB" -lt "$CRIT_AVAIL_MB" ] && { LEVEL="crit"; }
[ "$SWAP_PCT"    -ge "$CRIT_SWAP_PCT"  ] && { LEVEL="crit"; }
[ "$PSI"         -ge "$CRIT_PSI"       ] && { LEVEL="crit"; }

# An OOM kill since last run is always at least a warning on its own.
if [ -n "$OOM_HINT" ] && [ "$LEVEL" = "ok" ]; then
  LEVEL="warn"; add_reason "OOM kill detected"
fi

LAST="$(cat "$STATE_FILE" 2>/dev/null || echo ok)"
log "check: avail=${MEM_AVAIL_MB}MB swap=${SWAP_PCT}% psi=${PSI}% churn=${CHURN}pg level=$LEVEL reasons='${REASONS:-none}' (last=$LAST force=$FORCE)"

STATUS_BODY="$(printf '<b>%d MB</b> available · swap <b>%d%%</b> (%d/%d MB) · PSI <b>%d%%</b>' \
  "$MEM_AVAIL_MB" "$SWAP_PCT" "$SWAP_USED_MB" "$SWAP_TOTAL_MB" "$PSI")"

case "$LEVEL" in
  crit)
    notify critical "⚠  Memory critically low" \
"$(printf '%s\n\n<b>Why:</b> %s\n\n<b>Top consumers:</b>\n%s%s' \
   "$STATUS_BODY" "${REASONS:-pressure}" "$(top_consumers)" \
   "${OOM_HINT:+$'\n\n'<b>Recent OOM:</b>$'\n'$OOM_HINT}")"
    ;;
  warn)
    # Only re-warn on transition into warn, or when forced, to avoid nagging.
    if [ "$LAST" = "ok" ] || [ "$FORCE" -eq 1 ]; then
      notify normal "Memory getting tight" \
"$(printf '%s\n\n<b>Why:</b> %s\n\n<b>Top consumers:</b>\n%s%s' \
   "$STATUS_BODY" "${REASONS:-pressure}" "$(top_consumers)" \
   "${OOM_HINT:+$'\n\n'<b>Recent OOM:</b>$'\n'$OOM_HINT}")"
    fi
    ;;
  ok)
    [ "$FORCE" -eq 1 ] && notify normal "Memory OK" "$STATUS_BODY"
    ;;
esac

echo "$LEVEL" > "$STATE_FILE"
tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
exit 0
