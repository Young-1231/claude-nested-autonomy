#!/usr/bin/env bash
# Tier-2 supervisor: re-invoke the headless "brain" forever, one cycle at a time.
# Launch detached:  tmux new-session -d -s driver 'bash supervisor.sh'
# The brain does ONE concrete action per cycle, writes real output to STATUS, exits;
# this loop restarts it. Frequent-restart + checkpoint-resume is the fault model.
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p logs
n=0
while true; do
  n=$((n+1))
  echo "---- cycle $n $(date -u) ----" >> logs/driver.log
  # timeout guards a hung cycle; --dangerously-skip-permissions lets it act unattended.
  timeout 1500 claude -p "$(cat prompts/driver.md)" \
      --dangerously-skip-permissions >> logs/driver.log 2>&1 \
      || echo "[supervisor] cycle $n failed/timed out $(date -u)" >> logs/driver.log
  sleep 30          # brief gap so a tight crash-loop can't spin; tune as needed
done
