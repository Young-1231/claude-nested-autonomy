#!/usr/bin/env bash
# lib/sweep_orphans.sh — sweep GPU/RAM-holding worker orphans a pool leaves behind.
#
# Usage:
#   bash lib/sweep_orphans.sh [pattern]           # DRY-RUN: list what WOULD be killed
#   bash lib/sweep_orphans.sh [pattern] --kill    # actually kill them (signal $SIG, default TERM)
#   SIG=KILL bash lib/sweep_orphans.sh [pat] --kill   # escalate for processes that ignore TERM
#   source lib/sweep_orphans.sh; sweep_orphans <pattern> [--kill]
#
# After a worker pool (Ray / torchrun / vLLM) exits it commonly leaves orphan processes still
# holding GPU memory — the NEXT run then OOMs (hard-rule #8). Sweep them between runs.
#
# SCAR (hard-rule #7, sentinels self-match): NEVER `pkill -f <pat>` — the sweeper's OWN command
# line contains <pat>, so `pkill -f` kills itself / the supervisor. We `ps` to get the PID then
# `kill <pid>`, and explicitly drop our own PID, our parent, `grep`, and anything whose argv
# mentions this script. Default is DRY-RUN; you must pass --kill to terminate anything.
set -uo pipefail

DEFAULT_PATTERN='ray::|raylet|plasma_store|gcs_server|torchrun|torch\.distributed\.run|torch\.distributed\.elastic|vllm|EngineCore|pt_main_thread|multiprocessing\.(spawn|resource_tracker)'
SIG="${SIG:-TERM}"
# our own helper scripts — a shell running one of these carries the pattern in its argv and would
# self-match (the very `pkill -f` scar this script exists to avoid); exclude them + our ancestors.
# AND exclude our own process GROUP: the transient `grep`/`awk` co-processes in our own pipeline
# share our pgid, and a pattern that mentions this machinery would otherwise match them (reproduced).
SELF_RE='(healthcheck|launch_worker|sweep_orphans|assert_gate|restart_supervisor)\.sh'
MYPGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"

have() { command -v "$1" >/dev/null 2>&1; }

_pidchain() {    # this PID + all ancestors, space-padded — never kill the chain that launched us
  local pid=$$ out=""
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    out="$out $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) break ;; esac
  done
  printf ' %s ' "$out"
}

gpu_pid_set() {  # space-delimited list of GPU-holding PIDs (ground truth); empty if no nvidia-smi
  have nvidia-smi || return 0
  nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null \
    | tr -d ' ' | grep -E '^[0-9]+$' | paste -sd' ' - || true
}

find_orphans() { # print "PID<TAB>RSS_kB<TAB>GPU?<TAB>ARGS" per match, anchored + self-excluded
  local pat="$1" gpuset ex; gpuset=" $(gpu_pid_set) "; ex=$(_pidchain)
  ps -eo pid=,pgid=,rss=,args= 2>/dev/null \
    | grep -E "$pat" | grep -v grep \
    | awk -v ex="$ex" -v self="$SELF_RE" -v gs="$gpuset" -v mypg="$MYPGID" '
        (mypg!="" && $2==mypg) { next }                   # never our own process group (the grep/awk co-procs)
        index(ex, " " $1 " ") { next }                    # never kill the sweeper or its ancestors
        ($0 ~ self)          { next }                     # never match one of our own helper scripts
        {
          pid=$1; rss=$3
          gpu=(index(gs, " " pid " ") ? "GPU" : "-")
          $1=""; $2=""; $3=""; sub(/^[ \t]+/, "")
          printf "%s\t%s\t%s\t%s\n", pid, rss, gpu, $0
        }'
}

sweep_orphans() {
  local pat="$DEFAULT_PATTERN" kill=0 a
  for a in "$@"; do
    case "$a" in
      --kill)    kill=1 ;;
      --dry-run) kill=0 ;;
      -*)        echo "[sweep] unknown flag: $a" >&2; return 2 ;;
      *)         pat="$a" ;;
    esac
  done

  local rows; rows=$(find_orphans "$pat")
  if [ -z "$rows" ]; then
    echo "[sweep] no orphans match: $pat"
    return 0
  fi

  echo "[sweep] pattern: $pat   signal: $SIG   mode: $([ "$kill" -eq 1 ] && echo KILL || echo DRY-RUN)"
  printf 'PID\tRSS_kB\tGPU\tARGS\n'
  printf '%s\n' "$rows"

  local pid rest
  printf '%s\n' "$rows" | while IFS=$'\t' read -r pid rest; do
    [ -n "$pid" ] || continue
    if [ "$kill" -eq 1 ]; then
      if kill -s "$SIG" "$pid" 2>/dev/null; then
        echo "[sweep] sent $SIG -> pid=$pid"
      else
        echo "[sweep] kill failed pid=$pid (already gone, or a host-namespace orphan you can't kill from inside a container — flag the host)" >&2
      fi
    else
      echo "[sweep] DRY-RUN would: kill -s $SIG $pid"
    fi
  done

  [ "$kill" -eq 1 ] || echo "[sweep] dry-run only — re-run with --kill to terminate (SIG=KILL to escalate)."
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  sweep_orphans "$@"
fi
