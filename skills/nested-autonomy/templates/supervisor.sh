#!/usr/bin/env bash
# Tier-2 supervisor: re-invoke the headless "brain" forever, one cycle at a time.
# Launch detached:  tmux new-session -d -s driver 'bash supervisor.sh'
# The brain does ONE concrete action per cycle, writes real output to STATUS, exits;
# this loop restarts it. Frequent-restart + checkpoint-resume is the fault model.
#
# Four escape hatches (so an unattended loop can NEVER run away — each prevents a real scar):
#   1. completion marker  — stop when the brain proves every gate passed
#   2. MAX_CYCLES hard cap — a stuck loop can't spin forever burning quota
#   3. NEEDS-USER pause    — halt on a real human fork instead of looping on it
#   4. idle auto-stop      — no progress AND nothing running -> stop, don't burn cycles
# (Scar: an early version with a never-matching marker + no cap spun for >1 day, spawning a
#  `claude -p` every cycle and burning subscription quota for nothing.)
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p logs

CYCLE="${CYCLE:-30}"                              # gap between cycles (seconds)
MAX_CYCLES="${MAX_CYCLES:-300}"                   # HARD cap — the loop can never run unbounded
IDLE_STOP="${IDLE_STOP:-4}"                       # stop after N consecutive no-progress + no-live-job cycles
DONE_MARKER="${DONE_MARKER:-ALL-GATES-PASSED}"    # brain writes this as a STANDALONE line when truly done
STATUS="${STATUS:-STATUS.md}"
SELF_TMUX="${SELF_TMUX:-driver}"                  # this supervisor's own tmux session name

# --- completion: the marker must be its OWN line (optionally markdown-decorated), NOT merely
#     mentioned in prose. A whole-file `grep DONE_MARKER` FALSE-COMPLETES the moment the brain
#     quotes the marker in a plan ("I'll write ALL-GATES-PASSED after the eval"). Anchor it.
#     (Scar: the brain quoted the marker in a cycle note -> loop stopped mid-training. Same class
#     as the `pkill -f` self-match: a sentinel grepped loosely matches its own mention.)
done_all() { grep -qaE "^[[:space:]>*#-]*${DONE_MARKER}[[:space:]]*$" "$STATUS" 2>/dev/null; }

# --- a real human-decision fork is pending: stop and wait. Match only an actual directive line
#     ("NEEDS-USER: ..."), NOT prose that mentions the word (avoids false pauses).
needs_user() { grep -qaE "^[[:space:]>*#-]*(🛑[[:space:]]*)?NEEDS-USER:" "$STATUS" 2>/dev/null; }

# --- is there a live sub-job worth monitoring? (any OTHER tmux session, OR a busy GPU) ---
#     During a legit long job there are no commits for a while, so "idle" must also require
#     nothing running — otherwise we'd kill a healthy multi-hour train/eval.
live_job() {
  tmux ls 2>/dev/null | cut -d: -f1 | grep -qvxF "$SELF_TMUX" && return 0
  command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null | grep -qE "[1-9][0-9]* %" && return 0
  return 1
}

echo "================ supervisor START $(date -u) pid=$$ MAX_CYCLES=$MAX_CYCLES IDLE_STOP=$IDLE_STOP ================" >> logs/driver.log
n=0; idle=0; last_head=""
while [ "$n" -lt "$MAX_CYCLES" ]; do
  # stop BEFORE spending a cycle if already done, or a human fork is pending
  if done_all;  then echo "================ COMPLETE ('$DONE_MARKER') after $n cycles $(date -u) ================" >> logs/driver.log; break; fi
  if needs_user; then echo "================ PAUSE: unresolved NEEDS-USER — awaiting human (cycle $n) $(date -u) ================" >> logs/driver.log; break; fi

  n=$((n+1))
  echo "---- cycle $n/$MAX_CYCLES $(date -u) ----" >> logs/driver.log
  # Each cycle is a FRESH `claude -p` (fresh context — no context rot); state is carried by STATUS,
  # not a growing conversation. timeout guards a hung cycle; skip-permissions lets it act unattended.
  timeout 1500 claude -p "$(cat prompts/driver.md)" \
      --dangerously-skip-permissions >> logs/driver.log 2>&1 \
      || echo "[supervisor] cycle $n failed/timed out $(date -u)" >> logs/driver.log

  # idle auto-stop: a cycle counts as PROGRESS only if it produced a new git commit (or you can
  # swap in your own progress probe). But suppress idle counting whenever a sub-job is still live.
  cur_head=$(git rev-parse HEAD 2>/dev/null)
  if [ "$cur_head" = "$last_head" ] && ! live_job; then
    idle=$((idle+1))
    echo "[supervisor] idle $idle/$IDLE_STOP (no new commit, no live job, GPU free)" >> logs/driver.log
    [ "$idle" -ge "$IDLE_STOP" ] && { echo "================ STOP: $IDLE_STOP idle cycles — halting to save quota $(date -u) ================" >> logs/driver.log; break; }
  else
    idle=0
  fi
  last_head="$cur_head"
  sleep "$CYCLE"
done
[ "$n" -ge "$MAX_CYCLES" ] && echo "================ STOP: hit MAX_CYCLES=$MAX_CYCLES without DONE — halting (check $STATUS) $(date -u) ================" >> logs/driver.log
echo "================ supervisor EXIT after $n cycles $(date -u) ================" >> logs/driver.log
