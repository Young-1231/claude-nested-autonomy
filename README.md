# claude-nested-autonomy

A Claude Code **skill** for driving long-running, multi-hour autonomous tasks with a
**3-tier nested-Claude loop** — self-driving, self-correcting, self-monitoring, self-analyzing —
that **survives SSH/session drops** and **fixes its own failures**.

Battle-tested driving a real **7B GRPO video-RL** project (multi-day training, dozens of crash→fix→resume
cycles) end-to-end with minimal human input.

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

## The problem it solves

A single interactive Claude session can't drive a 12-hour training run: it dies on disconnect,
it blocks on every step, and it can't both "charge ahead and fix things" and "reflect coolly for
the human" at once. This pattern splits those concerns across three nested loops:

- **Tier 1 (Orchestrator)** — the interactive session. Directs, analyzes results, decides, and
  surfaces genuine forks to the human. Self-paces with `/loop`.
- **Tier 2 (Driver / "brain")** — a headless `claude -p` re-invoked every cycle by a bash
  supervisor in `tmux`. Does one concrete action per cycle, diagnoses→fixes→retries, writes real
  output to STATUS, exits. Survives disconnects.
- **Tier 3 (Workers)** — detached long jobs (training/eval/build) under `tmux + setsid nohup`,
  with checkpoint + resume. Decoupled from Claude's lifecycle: Claude can crash and the job keeps running.

Tiers 1 & 2 are both Claude (the "nesting"). Going down a tier: longer time scale, more autonomy,
less human. **They coordinate ONLY through a shared `STATUS.md`** — progress board + instruction
board + audit log in one file.

## What makes it work (it's not the layer count)

- **Shared STATUS file as the single coordination bus.** No tier calls another; they read/write STATUS.
- **Persistence over liveness.** Long jobs survive SSH drops (`tmux + setsid nohup </dev/null`).
- **Frequent restart + checkpoint-resume as the fault model** — not "never crash".
- **Integrity guard** — never fabricate a gate; empty output = flush delay → re-run + cross-verify.
- **Single-controller rule** — steer by editing config / writing STATUS, NEVER by grabbing the process.
- **NEEDS-USER gate** — only stop for real forks (cost / irreversible / scientific fork / credential);
  otherwise keep working.

Each of the [eight hard rules](skills/nested-autonomy/SKILL.md#eight-hard-rules-each-prevents-a-real-failure-we-hit)
in the skill encodes a real failure the pattern was hardened against (SSH-drop job death, two-controller
collisions, `pkill -f` self-kill, engine-incompatible "fixes", host-namespace orphan processes, …).

## Prior art & how this differs

This pattern builds on well-known ideas; it's a specific, hardened *shape* of them for **durable,
human-supervised, mixed Claude + non-Claude (e.g. GPU) long jobs**.

- **[Ralph-Wiggum loop](https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/README.md)**
  (Anthropic's official plugin) — a single in-session loop that re-feeds one prompt via a Stop hook until a
  "completion promise", capped by `--max-iterations`. We **absorb** its two escape hatches (a completion
  signal `ALL-GATES-PASSED` + a max-cycles cap in `supervisor.sh`) and its **fresh-context-per-cycle**
  insight (each `claude -p` starts clean; STATUS carries the state → no context rot). We **differ** by
  adding the Tier-1 human-supervised orchestrator, detached non-Claude workers, and full session-death
  survival (headless + tmux, not just in-session) — so it fits multi-hour training jobs and tasks needing
  occasional human judgment, which Ralph explicitly isn't for.
- **[Subagents](https://code.claude.com/docs/en/agents) / [Agent Teams](https://code.claude.com/docs/en/agent-teams)
  / dynamic Workflows** (native Claude Code) — parallel agents inside one session. Use those for in-session
  parallel fan-out; use *this* when work must survive disconnects, run for hours, and include non-Claude
  jobs. Different axis (durability + sequential-resume vs in-session parallelism). They compose — a Tier-2
  cycle can spawn subagents/Workflows.
- **[Multi-agent coordination patterns](https://claude.com/blog/multi-agent-coordination-patterns)** (Anthropic) —
  the orchestrator-worker lineage our tiers map onto.
- **[autonomous-agent-harness](https://github.com/affaan-m/everything-claude-code)** (ECC) — cron-triggered
  isolated sessions bridged by persistent memory. A cron is an equally valid Tier-2 trigger to our bash
  supervisor; same core idea — a persistent file (our STATUS) as the cross-session bridge.
- **[Tmux-Orchestrator](https://github.com/absmartly/Tmux-Orchestrator)** — tmux-based multi-Claude orchestration.
- **[cc-sdd](https://github.com/gotalab/cc-sdd)** — spec-driven long-running implementation; our STATUS is the
  same "source-of-truth file" idea, generalized to any gated long task.

**One-line positioning:** Ralph in a loop, but *tiered* — a human-supervised orchestrator over a headless
self-correcting brain over detached GPU/long jobs, coordinated by one STATUS file, hardened with operational
rules for runs that must not die on disconnect.

## Install

Drop the skill into your Claude Code skills directory:

```bash
# user-level (all projects)
mkdir -p ~/.claude/skills
cp -r skills/nested-autonomy ~/.claude/skills/

# or project-level
mkdir -p .claude/skills
cp -r skills/nested-autonomy .claude/skills/
```

Claude Code auto-discovers it. Verify with `/help` (skills are listed) — or just ask Claude to
"set up nested autonomy for <task>".

## Usage

1. In a Claude Code session, ask: *"Use nested-autonomy to drive `<my long task>`."*
2. Claude scaffolds the three tiers from the templates: a crash-safe Tier-3 job, a `STATUS.md`,
   a Tier-2 `prompts/driver.md` + `supervisor.sh`, and a Tier-1 `prompts/monitor.md`.
3. It launches the brain (`tmux new-session -d -s driver 'bash supervisor.sh'`) and starts the
   Tier-1 `/loop`.
4. Walk away. Check back via `STATUS.md`; the human is pinged only on `NEEDS-USER` forks.

The templates (`skills/nested-autonomy/templates/`) are copy-and-fill: `supervisor.sh`, `driver.md`
(Tier-2 contract), `monitor.md` (Tier-1 loop), `STATUS.md` (coordination board).

## Repo layout

```
skills/nested-autonomy/
├── SKILL.md                 # the skill: when/how, the 8 rules, self-X mapping, checklist
└── templates/
    ├── supervisor.sh        # Tier-2 brain loop (while-true + claude -p in tmux)
    ├── driver.md            # Tier-2 brain contract (integrity + auth + env rules + gates)
    ├── monitor.md           # Tier-1 self-paced monitor loop (/loop)
    └── STATUS.md            # the shared coordination bus
```

## Pacing note

The model prompt cache has a ~5-minute TTL, so Tier-1 wakeups are cache-aware: under ~270s when
actively polling external state, 1200–1800s when idle (one cache miss buys a long wait). Don't sit
at exactly 300s.

## Caveats

This runs `claude -p --dangerously-skip-permissions` unattended and lets the brain edit files and
launch jobs. Run it in a sandbox/container you control, on a task you've scoped. Batch `claude -p`
generation shares your subscription rate limit — keep concurrency low.

## License

MIT
