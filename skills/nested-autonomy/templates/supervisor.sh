#!/usr/bin/env bash
# Tier-2 supervisor: re-invoke the headless "brain" forever, one cycle at a time.
# Launch detached:  tmux new-session -d -s driver 'bash supervisor.sh'
# The brain does ONE concrete action per cycle, writes real output to STATUS, exits;
# this loop restarts it. Frequent-restart + checkpoint-resume is the fault model.
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p logs

# Escape hatches (borrowed from the Ralph-Wiggum loop's --max-iterations + completion promise):
MAX_CYCLES="${MAX_CYCLES:-300}"            # hard cap so a stuck loop can't run forever
DONE_MARKER="${DONE_MARKER:-ALL-GATES-PASSED}"   # the brain writes this to STATUS.md when truly done
STATUS="${STATUS:-STATUS.md}"

n=0
while [ "$n" -lt "$MAX_CYCLES" ]; do
  n=$((n+1))
  echo "---- cycle $n $(date -u) ----" >> logs/driver.log
  # Each cycle is a FRESH `claude -p` (fresh context — no context rot); state is carried across
  # cycles by STATUS.md, not by a growing conversation. timeout guards a hung cycle;
  # --dangerously-skip-permissions lets it act unattended.
  timeout 1500 claude -p "$(cat prompts/driver.md)" \
      --dangerously-skip-permissions >> logs/driver.log 2>&1 \
      || echo "[supervisor] cycle $n failed/timed out $(date -u)" >> logs/driver.log
  # Completion signal: stop when the brain marks every gate done (its "completion promise").
  if grep -q "$DONE_MARKER" "$STATUS" 2>/dev/null; then
    echo "[supervisor] '$DONE_MARKER' found in $STATUS — all gates passed, stopping after cycle $n $(date -u)" >> logs/driver.log
    break
  fi
  sleep 30          # brief gap so a tight crash-loop can't spin; tune as needed
done
[ "$n" -ge "$MAX_CYCLES" ] && echo "[supervisor] hit MAX_CYCLES=$MAX_CYCLES without DONE — stopping (check STATUS.md)" >> logs/driver.log
