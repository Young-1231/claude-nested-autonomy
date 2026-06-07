#!/usr/bin/env bash
# lib/launch_worker.sh — crash-safe Tier-3 worker launcher.
#
# Usage:
#   bash lib/launch_worker.sh <session-name> <command...>
#   source lib/launch_worker.sh; launch_worker <session-name> <command...>
#
# Runs <command...> as a DETACHED long job that survives SSH drop / SIGHUP:
#   tmux new-session -d -s <name> "setsid nohup <cmd> </dev/null >> logs/<name>.log 2>&1"
#
# SCAR (hard-rule #1, persistence over liveness): plain `cmd &` background jobs DIE on
# disconnect. tmux gives a durable session; setsid + nohup detaches the process group so a
# SIGHUP from the dropped SSH client never reaches it; </dev/null stops it blocking on stdin.
# SCAR (hard-rule #3): frequent restart + checkpoint-resume IS the fault model — we make a
# checkpoint dir up front and print the resume command, so a crash is cheap, not catastrophic.
# SCAR (single-controller): refuse to clobber an existing same-named session.
set -uo pipefail

LOGDIR="${LOGDIR:-logs}"
CKPT_ROOT="${CKPT_ROOT:-checkpoints}"

have() { command -v "$1" >/dev/null 2>&1; }

launch_worker() {
  local name="${1:-}"; shift || true
  if [ -z "$name" ] || [ "$#" -eq 0 ]; then
    echo "usage: launch_worker <session-name> <command...>" >&2; return 2
  fi
  if ! have tmux; then
    echo "[launch_worker] FATAL: tmux not found — required for a durable, disconnect-proof session." >&2; return 3
  fi

  # single-controller: never clobber a live session of the same name
  if tmux has-session -t "$name" 2>/dev/null; then
    echo "[launch_worker] REFUSE: tmux session '$name' already exists — attach with: tmux attach -t $name" >&2
    return 4
  fi

  mkdir -p "$LOGDIR"
  local ckpt="$CKPT_ROOT/$name"; mkdir -p "$ckpt"
  local logf="$LOGDIR/$name.log"

  # quote the command safely for the shell that tmux will spawn
  local cmd; cmd=$(printf '%q ' "$@"); cmd=${cmd%% }

  # setsid is the scar; gracefully degrade if absent (e.g. stock macOS) — tmux still detaches.
  local setsid=""
  have setsid && setsid="setsid "

  tmux new-session -d -s "$name" "${setsid}nohup ${cmd} </dev/null >> $(printf '%q' "$logf") 2>&1"

  if ! tmux has-session -t "$name" 2>/dev/null; then
    echo "[launch_worker] FAILED to start session '$name' (see $logf)" >&2; return 5
  fi

  echo "[launch_worker] STARTED session=$name ckpt=$ckpt log=$logf $(date -u)"
  [ -n "$setsid" ] || echo "[launch_worker] note: 'setsid' absent — relying on tmux for detach (fine on macOS; on Linux install util-linux so SIGHUP can't reach the job)."
  echo "  watch:    tmux attach -t $name        (detach again: Ctrl-b d)"
  echo "  tail:     tail -f $logf"
  echo "  resume:   point your job's --resume/--ckpt at $ckpt (save small + often; resume-from-latest)"
  echo "  liveness: bash lib/healthcheck.sh      (GPU/PID is ground truth, not the log)"
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  launch_worker "$@"
fi
