# Where each "self-X" lives

Read WHEN: you need to know which tier/mechanism owns a given autonomous behavior, or you're
debugging "who is supposed to do X". Each self-X maps to a concrete loop or file, not a vibe.

- **Self-drive:** Tier-2 supervisor while-loop ("one action/cycle") + Tier-1 `/loop`
  self-pacing. The loops are the engine — nothing advances unless a loop ticks.
- **Self-feedback:** the shared STATUS file — every cycle reads the latest real state and
  reacts. STATUS is the feedback channel; there is no other.
- **Self-correct:** Tier-2 contract authorizes "error → read logs → root-cause → apply best
  fix → retry"; checkpoint-resume makes crashes recoverable; script comments accrue "verified
  fixes" (and the cross-run scars file) so the brain stops re-trying known dead ends.
- **Self-monitor:** Tier-1 cross-verifies brain liveness (session + GPU + log) and watches
  gates. Keep each `/loop` poll **self-contained** — re-derive state and carry the
  act-on-condition logic *inside* the poll. Don't rely on a persistent background watcher: the
  host can kill it and leave you blind. (See `lib/healthcheck.sh` for the cross-verified check.)
- **Self-analyze:** Tier-1 does an honest review on results (vs baseline, explain surprises,
  note limitations + statistical significance — **small samples are noisy**, a tiny subset can
  flip a "win" into a tie) and writes it up; surfaces genuine forks to the human.
