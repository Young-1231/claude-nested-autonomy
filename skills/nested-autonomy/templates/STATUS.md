# STATUS — <TASK NAME> (single source of truth + coordination bus)

> The Tier-2 brain updates this after every cycle/gate; Tier-1 reads it to monitor & steer.
> It is THREE things in one file: progress board + instruction board + audit log.
> Paste REAL command output for gates. Never mark a gate passed without it.
> Setup truth → `config.json`. Cross-run memory (verified scars from prior runs) → `${CLAUDE_PLUGIN_DATA:-./.nested-autonomy}/scars.md`.

## 🟢 ACTIVE — current gate = <Gx>
- **Directive:** <what the brain should be doing right now, 1-3 lines>
- **Roadmap:** G0 ✅ → G1 ✅ → **G2 (active)** → G3 → G4
- **Steering (Tier-1 → Tier-2):** `NEXT:` <instruction the brain applies next cycle, if any>
- **NEEDS-USER:** <only-a-human decision, verbatim — else omit this line (must start `NEEDS-USER:` so the supervisor's pause matcher fires)>

## Environment / hard-rules (scars; the brain must respect)
- <flag/setting that crashes your engine — never set>
- <OOM / resource levers that worked>
- pkill -f self-matches → ps for PID then kill; long jobs need tmux+setsid; GPU/PID = ground truth.

---
## Cycle log (append-only; newest on top). Each entry = REAL output.
### Cycle note — <UTC time> (<gate>, <what happened>)
- <real numbers / command output>
- liveness (cross-verified): tmux=… GPU=… log mtime=…
- intervention this cycle = <none / what you changed>
- next: <the one concrete next action>
