#!/usr/bin/env bash
# lib/healthcheck.sh — cross-verified Tier-1/Tier-2 liveness probe.
#
# Usage:
#   bash lib/healthcheck.sh                  # print one-line status; exit 0 if anything alive
#   source lib/healthcheck.sh; healthcheck   # same, as a function
#
# Prints ONE line covering: tmux session(s) present, GPU utilization + GPU-holding PIDs,
# latest cycle timestamp vs now (from logs/driver.log), and worker PIDs from ps.
#
# SCAR (hard-rule #2): GPU/PID is GROUND TRUTH; the log is NOT. A stale log mtime does NOT
# mean the job died (flush delay / quiet training phase), and a "GONE" relative-path tail can
# be a cwd mistake. So the verdict is decided by tmux + GPU + ps only; the log age is reported
# for context and never flips the verdict on its own. Always cross-verify, never trust one signal.
set -uo pipefail

LOG="${DRIVER_LOG:-logs/driver.log}"
DRIVER_TMUX="${DRIVER_TMUX:-driver}"
# anchored pool patterns (same family swept by lib/sweep_orphans.sh)
POOL_PATTERN="${POOL_PATTERN:-ray::|raylet|plasma_store|torchrun|torch\.distributed\.run|vllm|EngineCore|pt_main_thread}"
# our own helper scripts — a shell running one of these has the pool pattern in its argv and would
# self-match (the sentinel-self-match scar); exclude them, our whole ancestor chain, AND our own
# process group (the transient grep/awk co-processes in our pipeline share our pgid).
SELF_RE='(healthcheck|launch_worker|sweep_orphans|assert_gate|restart_supervisor)\.sh'
MYPGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"

have() { command -v "$1" >/dev/null 2>&1; }

_pidchain() {      # this PID + all ancestors, space-padded — so a controller that invoked us
                   # with the pattern on its command line can never be mistaken for a worker.
  local pid=$$ out=""
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    out="$out $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) break ;; esac
  done
  printf ' %s ' "$out"
}

tmux_sessions() {  # all session names, comma-joined ("" if none / no tmux)
  have tmux || return 0
  tmux ls 2>/dev/null | cut -d: -f1 | paste -sd, - || true
}

gpu_util() {       # max utilization across GPUs as "NN%", or "n/a"
  have nvidia-smi || { echo "n/a"; return 0; }
  nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
    | awk 'BEGIN{m=-1}{gsub(/ /,"");if($1+0>m)m=$1+0}END{print (m<0?"n/a":m"%")}'
}

gpu_pids() {       # PIDs holding a GPU (ground truth), one per line, empty if no nvidia-smi
  have nvidia-smi || return 0
  nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null \
    | tr -d ' ' | grep -E '^[0-9]+$' || true
}

pool_pids() {      # worker-pool PIDs via ps + ANCHORED grep (never pkill -f; never self-match)
  local ex; ex=$(_pidchain)
  ps -eo pid=,pgid=,args= 2>/dev/null \
    | grep -E "$POOL_PATTERN" | grep -v grep \
    | awk -v ex="$ex" -v self="$SELF_RE" -v mypg="$MYPGID" '
        (mypg!="" && $2==mypg) { next }
        { if (index(ex, " " $1 " ")) next; if ($0 ~ self) next; print $1 }' || true
}

file_mtime() {     # epoch seconds of a file's mtime (macOS/Linux); empty if missing
  local f=$1
  [ -e "$f" ] || return 0
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true
}

log_age() {        # seconds since logs/driver.log last changed, or "n/a"
  local m now; m=$(file_mtime "$LOG"); [ -n "$m" ] || { echo "n/a"; return 0; }
  now=$(date +%s); echo "$(( now - m ))s"
}

last_cycle() {     # most recent "---- cycle" banner line, or "(none)"
  local l=""
  [ -f "$LOG" ] && l=$(grep -aE "^---- cycle" "$LOG" 2>/dev/null | tail -1)
  [ -n "$l" ] && echo "$l" || echo "(none)"
}

healthcheck() {
  local sessions others gpu gp pp util_busy=0 driver_up=0 worker=0 alive=0 verdict
  sessions=$(tmux_sessions)
  others=$(printf '%s' "${sessions:-}" | tr ',' '\n' | grep -vxF "$DRIVER_TMUX" | grep -v '^$' | paste -sd, - || true)
  gpu=$(gpu_util)
  gp=$(gpu_pids | tr '\n' ' '); gp=${gp%% }
  pp=$(pool_pids | tr '\n' ' '); pp=${pp%% }
  local gpu_n pool_n
  gpu_n=$(printf '%s' "$gp" | wc -w | tr -d ' ')
  pool_n=$(printf '%s' "$pp" | wc -w | tr -d ' ')

  have tmux && tmux has-session -t "$DRIVER_TMUX" 2>/dev/null && driver_up=1
  case "$gpu" in n/a) ;; *) [ "${gpu%\%}" -gt 0 ] 2>/dev/null && util_busy=1 ;; esac

  # worker = anything real holding resources: GPU PID, pool PID, util>0, or any non-driver tmux
  { [ "${gpu_n:-0}" -gt 0 ] || [ "${pool_n:-0}" -gt 0 ] || [ "$util_busy" -eq 1 ] || [ -n "$others" ]; } && worker=1
  { [ "$driver_up" -eq 1 ] || [ "$worker" -eq 1 ]; } && alive=1

  [ "$alive" -eq 1 ] && verdict=ALIVE || verdict=DEAD
  echo "HEALTH verdict=$verdict driver[$DRIVER_TMUX]=$([ "$driver_up" -eq 1 ] && echo up || echo down)" \
       "tmux=[${sessions:-none}] gpu=$gpu gpu_pids=[${gp:-none}] pool_pids=[${pp:-none}]" \
       "log_age=$(log_age) last=\"$(last_cycle)\""

  [ "$alive" -eq 1 ] && return 0 || return 1
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  healthcheck
fi
