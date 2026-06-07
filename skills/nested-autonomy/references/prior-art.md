# Relation to prior art (and when to use a native feature instead)

This pattern stands on well-known ideas. **Use it only when its specific shape fits —
durable + human-supervised + mixed Claude/non-Claude jobs.** Otherwise reach for the
lighter native feature whose shape matches better; don't pay the 3-tier scaffolding cost
when a single in-session loop or a subagent fan-out would do.

## Ralph-Wiggum loop
Anthropic's official `ralph-wiggum` plugin: a single in-session loop that re-feeds one
prompt via a **Stop hook** until a "completion promise" string appears, capped by
`--max-iterations`.
- **We borrow:** its two escape hatches — a **completion signal** (`ALL-GATES-PASSED` in
  STATUS) and a **max-cycles cap** — plus its **fresh-context-per-cycle** insight (each
  `claude -p` starts clean; STATUS carries the state, so no context rot).
- **We differ:** we add the **Tier-1 human-supervised orchestrator** + **detached
  non-Claude workers** + **survival of full session death** (headless + tmux, not just
  in-session). That suits long GPU/training jobs and tasks that need occasional human
  judgment — which Ralph explicitly is *not* for.
- **Reach for Ralph instead** when the whole job is one Claude in one session that can
  watch itself to completion.

## Subagents / Agent Teams / dynamic Workflows (native Claude Code)
Parallel agents inside ONE session, sharing context and task-list.
- **Use those for** parallel **fan-out within a session**.
- **Use THIS pattern instead** when work must **survive disconnects, run for hours, and
  include non-Claude long jobs** (training/eval) — a different axis (durability +
  sequential-resume, not in-session parallelism).
- **They compose:** a Tier-2 cycle can itself spawn subagents / Workflows for fan-out.

## Cron-triggered harnesses (e.g. ECC `autonomous-agent-harness`)
Scheduled isolated sessions bridged by persistent memory.
- Our `supervisor.sh` bash-loop is **one** Tier-2 trigger; a **cron is an equally valid
  Tier-2 trigger** when the cadence is fixed rather than continuous.
- **Same core idea:** a persistent file (our STATUS) as the cross-session bridge.

## Spec-driven harnesses (cc-sdd, plan → work → review)
- Our STATUS is the same **source-of-truth file** notion, generalized from coding to any
  long task with verifiable gates.

## "Always give the agent a way to verify" (Boris Cherny's rule for Ralph)
- Our per-gate **verifiable acceptance check** is exactly this: the loop advances only on
  real, checkable output — never on the brain's say-so. See `lib/assert_gate.sh` for the
  programmatic enforcement of this rule.
