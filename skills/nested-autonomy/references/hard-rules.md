# Ten hard rules

Each rule below encodes a real failure this pattern was hardened against. The
parenthetical `(Scar: …)` notes are the original wound — preserve them; they are the
reason the rule exists.

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
7. **Sentinels self-match — match them ANCHORED, never loosely.** A token you search for can also
   match its own *mention*, firing the check by accident. Two scars, same class: (a) `pkill -f <pat>`
   killed the very script that contained `<pat>` → use `ps` to get the PID then `kill <pid>`; (b) a
   whole-file `grep ALL-GATES-PASSED` FALSE-COMPLETED the run the moment the brain *quoted* the marker
   in a plan ("I'll write ALL-GATES-PASSED after the eval") → match the marker only as its own line
   (`grep -E "^…ALL-GATES-PASSED…$"`) AND forbid the brain from typing it anywhere but the final line.
8. **Know your stack's incompatible "fixes".** Some memory/perf flags crash specific engines
   (e.g. vLLM + `expandable_segments:True`); host-namespace orphan processes can't be killed
   from inside a container; a worker pool (Ray/torchrun/vLLM) leaves GPU-holding orphans after exit —
   sweep them or the next run OOMs. Record these in `driver.md` so the brain stops re-trying dead ends.
9. **Bounded autonomy — the four escape hatches are mandatory, never optional.** Completion marker +
   `MAX_CYCLES` cap + `NEEDS-USER` pause + idle auto-stop (no progress AND nothing running). (Scar: a
   loop with a never-matching marker and no cap spun >1 day, re-spawning `claude -p` every cycle and
   burning quota for nothing.) Corollary: on a long run the cap WILL fire mid-task — Tier-1 restarts the
   supervisor, gating the restart on `no live session && marker-not-written` (tmux-session presence is
   the liveness ground truth; a stale EXIT banner in the log is not), so the detached worker loses nothing.
10. **A gate on a small eval sample can be noise.** A tiny subset has a wide CI (≈±11pp at 70 items),
    so a "pass", "regression", or ranking that small may not be real. Size gates adequately, or mark them
    provisional and confirm on a larger set before concluding. (Scar: a data-ablation "regression" and a
    "+5.7pt win" both dissolved into statistical ties when re-evaluated on a 5× larger sample.)
