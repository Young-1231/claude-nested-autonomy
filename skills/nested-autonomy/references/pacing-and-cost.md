# Pacing & cost

Read WHEN: choosing models for the tiers, setting `--model` on `claude -p`, or tuning
Tier-1 `/loop` wakeup intervals. Pull the model ids from `templates/config.json`.

## Cost: tier your models
Frontier model for Tier-1 reasoning/analysis and gate decisions; a **cheaper model for
Tier-2 cycles and batch sub-work** (e.g. distillation/data-gen) — most token volume should
sit on the cheap tier. Pass the model explicitly to `claude -p` (e.g. `--model sonnet`) for
the brain / batch jobs; don't rely on the session default. Tier-1 stays frontier because it
makes the irreversible calls (gate pass/fail, NEEDS-USER forks, commits).

## Pacing (cache-aware)
The model prompt cache has a ~5-minute TTL. For Tier-1 self-paced wakeups:
- Stay **under ~270s** when actively polling external state — keeps the cache warm.
- Jump to **1200–1800s** when genuinely idle (one cache miss buys a long wait — paying it
  once to sleep 20–30 min is cheaper than churning 5-min misses).
- **Don't sit at exactly 300s** — that straddles the TTL and reliably misses the cache.
- **Shorten near a gate/handoff** (you want to react fast); **lengthen during stable long
  runs** (nothing to do but wait for the worker).
