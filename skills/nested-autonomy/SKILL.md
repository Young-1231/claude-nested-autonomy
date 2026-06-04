---
name: nested-autonomy
description: >-
  Set up a 3-tier nested-Claude loop to drive a long-running, multi-hour autonomous task
  (model training, large migrations, multi-stage pipelines, batch generation) that must
  survive SSH/session drops and self-correct. Tier 1 = interactive orchestrator (this
  session, self-paced via /loop), Tier 2 = headless `claude -p` "brain" re-invoked by a
  bash supervisor loop in tmux, Tier 3 = detached long jobs. The tiers coordinate ONLY
  through a shared STATUS file (progress board + instruction board + audit log). Use when
  a task is too long to babysit interactively, needs to keep running across disconnects,
  and benefits from autonomous diagnose→fix→retry. Do NOT use for quick one-off tasks.
---

# Nested-Autonomy: 3-tier self-driving / self-correcting / self-monitoring loop

You are setting up (or operating) a **3-tier nested-Claude system** so a long task runs
autonomously for hours, survives disconnects, and corrects its own failures. Each tier is
one loop; the tiers talk only through a shared `STATUS.md`.

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

**Key intuition:** going down a tier, the time scale lengthens, autonomy rises, human
involvement drops. Tier 1 & 2 are BOTH Claude (that's the "nesting"); Tier 3 is usually
non-Claude long jobs (but can be more `claude -p` sub-agents if the work is itself agentic).

**Why three tiers, not one Claude doing everything:**
1. An interactive Claude dies on session/network drop — push execution down to headless +
   tmux so it survives disconnects.
2. Separating *decide/analyze* (Tier 1) from *execute/fix* (Tier 2) lets Tier 1 reflect
   coolly and answer to the human while Tier 2 charges ahead and fails fast — neither blocks.
3. Decoupling long jobs (Tier 3) from Claude's lifecycle: Claude can crash/restart and the
   job keeps running.

## When to use / when NOT
- **Use** when: the task is multi-hour; must keep running across disconnects; benefits from
  autonomous retry (training, large migrations, audits, batch generation, multi-stage pipelines).
- **Don't** use for: quick one-offs, single-shot commands, anything you'll watch to completion
  in one sitting. The scaffolding cost isn't worth it.

## How to scaffold (copy the templates, fill the blanks)
Templates live in `templates/` next to this file.
1. **Define the Tier-3 work unit first.** What is one job? (a training run, an eval, a build.)
   Make it crash-safe: run under `tmux + setsid nohup … </dev/null`, write checkpoints,
   enable resume-from-latest. Frequent-restart-and-resume is the fault model — not "never crash".
2. **Write `STATUS.md`** (`templates/STATUS.md`): the single coordination bus. Top section =
   the ACTIVE directive + gate. It is progress board + instruction board + audit log in one.
3. **Write `prompts/driver.md`** (Tier-2 brain contract; `templates/driver.md`): integrity
   rules, authorization & self-correction mandate, environment hard-rules (your scars), the
   gated roadmap, and "every cycle do exactly these checks + one concrete action".
4. **Write `supervisor.sh`** (`templates/supervisor.sh`) and launch the brain:
   `tmux new-session -d -s driver 'bash supervisor.sh'`.
5. **Start the Tier-1 loop** (you): run `prompts/monitor.md` (`templates/monitor.md`) via
   `/loop` (no interval → self-pace). Watch brain health + real milestones; commit at gates;
   surface real forks to the human.

## The shared STATUS file = the only coordination bus (most important piece)
- Tiers never call each other. They read/write `STATUS.md`.
- Tier 1 wants Tier 2 to change course → write a `NEXT:` / `USER DECISION:` line at the top
  (or edit the config script) so Tier 2 applies it next cycle. Do NOT kill/restart Tier 2's job.
- Tier 2 hits something only a human can decide (spend money, irreversible, major fork, missing
  credential) → write a `NEEDS-USER:` line, then keep doing other useful work. Never spin idle.
- Tier 1 greps `NEEDS-USER` each cycle and surfaces it.

## Eight hard rules (each prevents a real failure we hit)
1. **Persistence over liveness.** Long jobs run under `tmux + setsid nohup </dev/null` so an
   SSH drop / SIGHUP never kills them. (Scar: bg jobs died on disconnect.)
2. **GPU/PID is ground truth, not the log.** A stale log ≠ dead job; a "GONE" relative-path
   tail can be a cwd mistake. Cross-verify with `tmux has-session` + `nvidia-smi` + `ps`.
3. **Frequent restart + checkpoint-resume IS the fault model.** Don't chase "never crash";
   make every crash cheap to resume (save_freq small, resume=auto, prune superseded ckpts).
4. **Single-controller rule — steer by editing config, never by grabbing the process.** One
   job, one controller. Tier 1 changes Tier 2's run by editing the script / writing STATUS and
   letting Tier 2 apply it — NEVER kill/restart it yourself. (Scar: two controllers collided,
   wasted ~40 steps.)
5. **Integrity guard: never fabricate a gate.** Empty output usually = flush delay → re-run +
   cross-verify before concluding. Paste REAL command output for every gate; if it failed, say so.
6. **NEEDS-USER gate: only stop for real forks.** Big cost / irreversible / scientific fork /
   missing credential. Otherwise keep working; never idle-wait for a human.
7. **`pkill -f <pattern>` self-matches — use `ps` to get the PID, then `kill <pid>`.** A pattern
   that also matches your own command/script kills itself mid-run. (Scar: `pkill -f` killed the
   script that contained the pattern.)
8. **Know your stack's incompatible "fixes".** Some memory/perf flags crash specific engines
   (e.g. vLLM + `expandable_segments:True`); host-namespace orphan processes can't be killed
   from inside a container. Record these in `driver.md` so the brain stops re-trying them.

## Where each "self-X" lives
- **Self-drive:** Tier-2 supervisor while-loop ("one action/cycle") + Tier-1 `/loop` self-pacing.
- **Self-feedback:** the shared STATUS file — every cycle reads the latest real state and reacts.
- **Self-correct:** Tier-2 contract authorizes "error → read logs → root-cause → apply best fix →
  retry"; checkpoint-resume makes crashes recoverable; script comments accrue "verified fixes".
- **Self-monitor:** Tier-1 cross-verifies brain liveness (session+GPU+log) and watches gates.
- **Self-analyze:** Tier-1 does an honest review on results (vs baseline, explain surprises, note
  limitations) and writes it up; surfaces genuine forks to the human.

## Pacing (cache-aware)
The model prompt cache has a ~5-minute TTL. For Tier-1 self-paced wakeups: stay under ~270s when
actively polling external state; jump to 1200–1800s when genuinely idle (one cache miss buys a
long wait). Don't sit at exactly 300s. Shorten near a gate/handoff; lengthen during stable long runs.

## New-task startup checklist
1. Decide the Tier-3 work unit; make it crash-safe (tmux+setsid, checkpoint, resume).
2. Write `STATUS.md` (active directive + gate at top).
3. Write `prompts/driver.md` (Tier-2 contract: integrity + authorization + env hard-rules + gates).
4. Write `supervisor.sh`; `tmux new-session -d -s driver 'bash supervisor.sh'`.
5. Start the Tier-1 `/loop` with `prompts/monitor.md`; watch health + gates, commit at gates,
   surface forks.
