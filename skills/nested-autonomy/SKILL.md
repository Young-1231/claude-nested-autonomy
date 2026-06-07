---
name: nested-autonomy
description: >-
  Run an overnight / unattended / multi-hour autonomous task that must survive an SSH or
  session drop and self-correct — model training, large migrations, multi-stage pipelines,
  batch generation: anything too long to babysit that benefits from autonomous diagnose→fix→retry.
  Stand up a 3-tier nested-Claude loop: Tier 1 = interactive orchestrator (this session, /loop
  self-paced); Tier 2 = headless `claude -p` "brain" re-invoked by a bash supervisor loop in tmux;
  Tier 3 = detached long jobs. Tiers coordinate ONLY through a shared STATUS file. Triggers: "run
  this overnight", "keep going after I disconnect", "self-correcting training run", "unattended
  migration/batch". Do NOT use for quick one-offs you'll watch to completion in one sitting.
---

# Nested-Autonomy: 3-tier self-driving / self-correcting / self-monitoring loop

You are setting up (or operating) a **3-tier nested-Claude system** so a long task runs
autonomously for hours, survives disconnects, and corrects its own failures. Each tier is
one loop; the tiers talk only through a shared `STATUS.md`. (Anthropic skill categories:
business-process automation + infrastructure ops + runbook.)

```
┌ Tier 1 — Orchestrator (interactive Claude + human) ── seconds–min, human-facing ─┐
│  directs · analyzes results · decides · steers via STATUS · surfaces real forks   │
│  ┌ Tier 2 — Driver / "brain" (headless `claude -p`, restarted by a bash loop) ──┐ │
│  │  one action/cycle · diagnose→fix→retry · writes real output to STATUS · exits │ │
│  │  ┌ Tier 3 — Workers (detached jobs: train / eval / build / download) ──────┐ │ │
│  │  │  tmux + setsid nohup · checkpoint + resume · just run & save            │ │ │
│  │  └────────────────────────────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Key intuition:** down a tier = longer time scale, more autonomy, less human. Tiers 1 & 2 are
BOTH Claude (the "nesting"); Tier 3 is usually non-Claude long jobs (or more `claude -p` if the
work is itself agentic).

**Why three tiers, not one:** (1) an interactive Claude dies on a session/network drop — headless +
tmux survives it; (2) splitting *decide/analyze* (T1) from *execute/fix* (T2) lets one reflect for
the human while the other fails fast — neither blocks; (3) detaching long jobs (T3) from Claude's
lifecycle means Claude can crash/restart while the job runs on.

**When NOT to use:** skip the scaffolding for quick one-offs / single-shot commands / anything
you'll watch to completion in one sitting — the setup cost isn't worth it.

## The shared STATUS file = the only coordination bus (most important piece)
- Tiers never call each other. They read/write `STATUS.md` (`templates/STATUS.md`).
- Top section = the ACTIVE directive + gate. It is progress board + instruction board + audit log in one.
- Tier 1 wants Tier 2 to change course → write a `NEXT:` / `USER DECISION:` line at the top
  (or edit the config) so Tier 2 applies it next cycle. Do NOT kill/restart Tier 2's job.
- Tier 2 hits something only a human can decide (spend money, irreversible, major fork, missing
  credential) → write a `NEEDS-USER:` line, then keep doing other useful work. Never spin idle.
- Tier 1 greps `NEEDS-USER` each cycle and surfaces it.

## Verification is the gate, not vibes
Every gate "pass" must be a **programmatic assertion** via `lib/assert_gate.sh` (state-changed /
file-nonempty / marker-anchored / metric≥thresh / session-dead) PLUS **real captured evidence** pasted
into STATUS. Empty output usually = flush delay → re-run + cross-verify first. Models fake "done"; an
asserted, evidenced gate can't be eyeballed away.

## Setup (config-driven, 5 steps)
0. **Read `templates/config.json`.** If absent or any field blank, gather from the user with
   **AskUserQuestion**: task name, sandbox path, the Tier-3 work-unit command, the gates,
   model tiers (Tier-1 vs Tier-2), concurrency cap. Write the filled `config.json`.
1. **Read cross-run scars.** `mkdir -p "${CLAUDE_PLUGIN_DATA:-./.nested-autonomy}"` then read (or
   seed from `templates/scars.md`) `…/scars.md` — verified stack-specific dead-ends from prior runs.
   Fold them into `driver.md` so the brain skips them.
2. **Copy templates + helpers into the project.** Copy `lib/` + `hooks/` as-is; copy `templates/STATUS.md`,
   `templates/supervisor.sh`, `templates/config.json` to the project root; **`mkdir -p prompts` and copy
   `templates/driver.md` → `prompts/driver.md` and `templates/monitor.md` → `prompts/monitor.md`** (the
   supervisor cats `prompts/driver.md`). Fill them from `config.json` (task, command, gates, `--model` per tier).
3. **Define the Tier-3 work unit crash-safe** (`lib/launch_worker.sh`): `tmux + setsid nohup
   </dev/null`, checkpoints, resume-from-latest. Frequent-restart-and-resume IS the fault model.
4. **Launch the brain:** `tmux new-session -d -s driver 'bash supervisor.sh'`.
5. **Start the Tier-1 loop** (you): run `prompts/monitor.md` via `/loop` (no interval →
   self-pace). Watch brain health + gates; commit at gates; surface real forks to the human.

## Pre-placed helpers (orchestrate these; don't re-derive boilerplate each cycle)
- `lib/healthcheck.sh` — cross-verified liveness: tmux + GPU + log-mtime + PID (no single signal trusted).
- `lib/launch_worker.sh` — crash-safe Tier-3 launcher (tmux + `setsid nohup </dev/null` + checkpoint dir).
- `lib/sweep_orphans.sh` — kill GPU/RAM-holding worker orphans via `ps`→`kill <pid>` (NEVER `pkill -f`).
- `lib/assert_gate.sh` — programmatic gate assertions; the only thing allowed to flip a gate.
- `lib/restart_supervisor.sh` — gated supervisor restart: only when `no live session && done-marker-not-written`.

## Safety hook (enable it — this runs unattended with skipped permissions)
Because Tier-2/3 run `claude -p --dangerously-skip-permissions` with no human at the keyboard, wire
`hooks/careful-guard.sh` (PreToolUse) to block catastrophic ops (`rm -rf /`, `DROP TABLE`, force-push,
`kubectl delete`) while unattended — see `hooks/README.md` for the settings.json snippet.

## Cross-run memory (scars)
`${CLAUDE_PLUGIN_DATA:-./.nested-autonomy}/scars.md` accumulates verified stack-specific hard-rules
across runs (append-only). Read at setup; when a NEW dead-end is **confirmed** (not suspected), append
it so future runs and the brain stop re-trying it.

## Read-on-demand references (pointers, not inline)
- `references/hard-rules.md` — the 10 hard rules + full scars. Read at setup and **before trusting any gate**.
- `references/troubleshooting.md` — symptom runbook. Read when stuck > 2 cycles / gate won't pass / orphans / OOM / false-completion.
- `references/prior-art.md` — Ralph-Wiggum / subagents / cron / spec-driven. Read when deciding if this pattern is even the right tool.
- `references/self-x-mapping.md` — self-drive/correct/monitor/analyze → tiers. Read when wiring a new tier's responsibilities.
- `references/pacing-and-cost.md` — model tiering + cache-aware `/loop` pacing (5-min TTL). Read when setting intervals or per-tier models.
