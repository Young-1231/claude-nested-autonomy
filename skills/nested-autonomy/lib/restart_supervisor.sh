#!/usr/bin/env bash
# lib/restart_supervisor.sh — gated relaunch of the Tier-2 supervisor.
#
# Usage:
#   bash lib/restart_supervisor.sh            # relaunch ONLY if safe; else refuse + explain
#   bash lib/restart_supervisor.sh --force    # skip the gates (you accept double-controller risk)
#   source lib/restart_supervisor.sh; restart_supervisor
#
# On a long run the MAX_CYCLES cap WILL fire mid-task (hard-rule #9). Relaunching continues with
# ZERO loss — the detached Tier-3 worker kept running across the supervisor gap. But a blind
# "restart whenever the supervisor isn't running" loops FOREVER:
#   SCAR: a stale EXIT/STOP banner sits in logs/driver.log after a CLEAN finish too, so it must
#   NOT trigger a restart. Gate on the GROUND-TRUTH pair — (no live 'driver' tmux session) AND
#   (done-marker NOT written, anchored ^…$ in STATUS.md). tmux-session presence is the liveness
#   truth; a log banner is not. We read the CURRENT run's outcome by anchoring to the LATEST
#   'supervisor START' banner, so a previous run's COMPLETE/PAUSE/EXIT can't fool the gate.
set -uo pipefail

STATUS="${STATUS:-STATUS.md}"
LOG="${DRIVER_LOG:-logs/driver.log}"
DRIVER_TMUX="${DRIVER_TMUX:-driver}"
SUPERVISOR="${SUPERVISOR:-supervisor.sh}"

have() { command -v "$1" >/dev/null 2>&1; }

# done-marker must match what the supervisor writes — same precedence (env > config.json > default),
# so a user who customizes done_marker doesn't gate the restart on the wrong token.
CONFIG="${CONFIG:-config.json}"
cfg() { [ -f "$CONFIG" ] && have jq && jq -r "$1 // empty" "$CONFIG" 2>/dev/null; }
DONE_MARKER="${DONE_MARKER:-$(cfg '.done_marker')}"; DONE_MARKER="${DONE_MARKER:-ALL-GATES-PASSED}"

supervisor_live() { have tmux && tmux has-session -t "$DRIVER_TMUX" 2>/dev/null; }

done_written() {  # marker on its OWN line in STATUS (anchored — a mere mention must not count)
  [ -f "$STATUS" ] && grep -qaE "^[[:space:]>*#-]*${DONE_MARKER}[[:space:]]*\$" "$STATUS" 2>/dev/null
}

needs_user() {    # an unresolved human fork is pending → surface it, don't restart over it
  [ -f "$STATUS" ] && grep -qaE "^[[:space:]>*#-]*(🛑[[:space:]]*)?NEEDS-USER:" "$STATUS" 2>/dev/null
}

log_after_latest_start() {  # the slice of the log belonging to the CURRENT run only
  [ -f "$LOG" ] || return 0
  local ln
  ln=$(grep -naE "^=+ supervisor START" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  [ -n "$ln" ] && tail -n +"$ln" "$LOG" || true
}

current_run_finished_clean() {  # COMPLETE or PAUSE banner WITHIN the current run's slice
  log_after_latest_start | grep -qaE "^=+ (COMPLETE|PAUSE)"
}

restart_supervisor() {
  local force="${1:-}"
  if [ "$force" = "--force" ]; then
    echo "[restart] --force: skipping gates (accepting double-controller risk)."
  else
    if supervisor_live; then
      echo "[restart] REFUSE: tmux session '$DRIVER_TMUX' is ALIVE — single-controller; never double-launch." >&2; return 1
    fi
    if done_written; then
      echo "[restart] REFUSE: done-marker '$DONE_MARKER' is written in $STATUS — task complete, nothing to restart." >&2; return 1
    fi
    if needs_user; then
      echo "[restart] REFUSE: an unresolved NEEDS-USER fork is pending in $STATUS — surface it to a human, don't loop over it." >&2; return 1
    fi
    if current_run_finished_clean; then
      echo "[restart] REFUSE: the current run ended on a COMPLETE/PAUSE banner (anchored to latest START), not a MAX_CYCLES cap — not restarting." >&2; return 1
    fi
  fi

  if ! have tmux; then echo "[restart] FATAL: tmux not found." >&2; return 3; fi
  [ -f "$SUPERVISOR" ] || { echo "[restart] FATAL: $SUPERVISOR not found in $(pwd)." >&2; return 3; }

  # last-moment re-check to avoid racing another controller into a double-launch
  if supervisor_live; then echo "[restart] REFUSE (race): '$DRIVER_TMUX' just came alive — aborting." >&2; return 1; fi

  tmux new-session -d -s "$DRIVER_TMUX" "bash $(printf '%q' "$SUPERVISOR")"
  if tmux has-session -t "$DRIVER_TMUX" 2>/dev/null; then
    echo "[restart] RELAUNCHED supervisor in tmux '$DRIVER_TMUX' ($(date -u))"
  else
    echo "[restart] FAILED to relaunch — check $LOG" >&2; return 4
  fi
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  restart_supervisor "$@"
fi
