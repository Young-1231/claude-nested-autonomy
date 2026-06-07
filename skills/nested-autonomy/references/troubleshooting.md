# Troubleshooting — symptom-driven runbook

Enter here by the **symptom you're seeing**, not by what you wanted to do. Each entry:
(1) cross-verify commands → (2) likely cause → (3) fix → (4) helper/rule that applies.

**One law underneath most of these:** GPU + PID + tmux-session presence are ground truth.
Logs, tails, and EXIT banners lie (stale writes, cwd mistakes, flush lag). Never conclude from
one signal — cross-verify before you act. Rule numbers below point at `references/hard-rules.md`.

---

### A job looks dead — the log went quiet, or a tail shows "GONE"
1. **Cross-verify (don't trust the log):**
   ```bash
   tmux has-session -t <job> 2>/dev/null && echo SESSION-LIVE || echo NO-SESSION
   command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader
   ps -o pid,etime,%cpu,cmd -p "$(pgrep -f '<job-binary>' | head -1)" 2>/dev/null
   stat -f %m logs/<job>.log 2>/dev/null || stat -c %Y logs/<job>.log   # log mtime vs now
   ```
2. **Likely cause:** a *stale* log (job is busy on GPU, just not printing) or a `GONE`/empty
   relative-path tail caused by reading from the wrong cwd — **not** a dead job.
3. **Fix:** if the session is live, the GPU is busy, and the PID is running, the job is fine —
   leave it alone. Only if all three say dead (no session, GPU idle, no PID) treat it as crashed
   and resume from the latest checkpoint.
4. **Applies:** `lib/healthcheck.sh` (tmux+GPU+log-mtime+PID in one shot). Rule 2 (GPU/PID is
   ground truth) + Rule 3 (resume from checkpoint, don't panic).

---

### The loop FALSE-COMPLETED mid-task (supervisor stopped, gates not actually done)
1. **Cross-verify:**
   ```bash
   grep -nE '<DONE_MARKER>' STATUS.md            # how many times does the literal appear?
   grep -aE "^[[:space:]>*#-]*<DONE_MARKER>[[:space:]]*$" STATUS.md   # anchored: real done-lines only
   ```
   If the loose grep matches but the anchored one shows the marker only inside a prose sentence,
   that's your false trip.
2. **Likely cause:** the brain *quoted* the done-marker in a plan or cycle note ("I'll write
   ALL-GATES-PASSED after the eval"). A whole-file grep self-matched that mention and halted the run.
3. **Fix:** the supervisor must match the marker ANCHORED as its own line
   (`done_all()` uses `grep -qaE "^[[:space:]>*#-]*${DONE_MARKER}[[:space:]]*$"`), AND the brain is
   forbidden from typing the literal anywhere but the final bare line — in prose it's "the
   done-marker". Delete the stray mention from STATUS, then restart via the gated path below.
4. **Applies:** Rule 7 (sentinels self-match — anchor them). `templates/driver.md` done-marker
   discipline; `lib/assert_gate.sh` marker-anchored assertion. Same class as the `pkill -f`
   self-match.

---

### The next run OOMs immediately (before it does any real work)
1. **Cross-verify:**
   ```bash
   command -v nvidia-smi >/dev/null && nvidia-smi   # is VRAM already full with no live job?
   ps -eo pid,rss,cmd | grep -E 'ray::|torchrun|vllm|multiprocessing' | grep -v grep
   ```
2. **Likely cause:** a prior worker pool (Ray / torchrun / vLLM) exited but left GPU/RAM-holding
   orphan processes behind; the fresh run can't allocate.
3. **Fix:** sweep the orphans — get each PID with `ps`, then `kill <pid>` (never `pkill -f <pat>`,
   it self-matches the sweeper). Confirm VRAM is released before relaunching.
4. **Applies:** `lib/sweep_orphans.sh` (ps→kill pid, never pkill -f). Rule 8 (worker pools leave
   GPU-holding orphans) + Rule 7 (pkill self-matches).

---

### The supervisor stopped but the task isn't done
1. **Cross-verify:**
   ```bash
   tmux ls 2>/dev/null | grep -c '^driver:'                       # is a supervisor already live?
   tail -3 logs/driver.log                                        # STOP: hit MAX_CYCLES / idle?
   grep -aE "^[[:space:]>*#-]*<DONE_MARKER>[[:space:]]*$" STATUS.md   # marker truly written?
   awk '/ supervisor START /{ln=NR} END{print ln}' logs/driver.log   # anchor checks to LATEST START
   ```
2. **Likely cause:** `MAX_CYCLES` or idle-auto-stop fired. On a long run the cap is EXPECTED to fire
   mid-task — it's a guardrail, not a failure. The detached Tier-3 worker kept running across the gap.
3. **Fix:** relaunch the supervisor, but GATE the restart on `no live driver session && done-marker
   not written`. Use tmux-session presence as liveness ground truth — a stale `EXIT`/`STOP` banner
   from the previous run still sits in the log, so anchor any log read to the LATEST `START` line, or
   a stale banner triggers an endless re-restart.
4. **Applies:** `lib/restart_supervisor.sh` (does exactly this gating). Rule 9 corollary; `templates/monitor.md`
   restart action.

---

### The loop spun for a day burning quota with nothing to show
1. **Cross-verify:**
   ```bash
   grep -c '^---- cycle' logs/driver.log         # how many cycles fired?
   grep -aE "^[[:space:]>*#-]*<DONE_MARKER>[[:space:]]*$" STATUS.md   # could the marker EVER match?
   ```
   Many cycles, marker never matchable → runaway.
2. **Likely cause:** a never-matching completion marker (typo, wrong anchor, marker the brain never
   writes) combined with no hard cap — the loop re-spawns `claude -p` every cycle forever.
3. **Fix:** the four escape hatches are MANDATORY, never optional — completion marker + `MAX_CYCLES`
   hard cap + `NEEDS-USER` pause + idle auto-stop (no progress AND nothing live). Verify the marker
   the supervisor greps for is byte-identical to what the brain is told to write, and that `MAX_CYCLES`
   is set. Kill the runaway session, fix the marker, relaunch.
4. **Applies:** `templates/supervisor.sh` (the four hatches). Rule 9. The original scar that motivated
   the cap.

---

### A gate "passed" (or "regressed", or a ranking flipped) but I'm not sure it's real
1. **Cross-verify:**
   ```bash
   # how many items did this gate evaluate? a tiny n has a wide CI (~±11pp at 70 items)
   wc -l eval/results.jsonl
   ```
2. **Likely cause:** the gate ran on too small a sample. At ~70 items the confidence interval is
   roughly ±11pp, so a "pass", a "regression", or a small win/ranking may be pure noise.
3. **Fix:** size gates adequately, or mark the result **provisional** and confirm on a ~5× larger set
   before concluding. (Scar: both a data-ablation "regression" and a "+5.7pt win" dissolved into
   statistical ties on a 5× sample.) Don't commit/announce a borderline result off the small set.
4. **Applies:** Rule 10 (small-sample noise). `templates/driver.md` provisional-gate rule;
   `lib/assert_gate.sh` metric≥threshold assertion (feed it the larger-set numbers).

---

### Two controllers fought over one job (wasted steps, conflicting edits)
1. **Cross-verify:**
   ```bash
   tmux ls                                 # is more than one thing driving the same job?
   grep -nE 'NEXT:|USER DECISION:' STATUS.md | tail -3
   ```
2. **Likely cause:** Tier-1 grabbed/killed/restarted the process that Tier-2 already owns — two hands
   on one wheel. (Scar: collided controllers wasted ~40 steps.)
3. **Fix:** single-controller rule. One job, one controller. Tier-1 steers ONLY by editing the config
   script or writing a `NEXT:` line in STATUS and letting Tier-2 apply it next cycle — it never kills or
   restarts Tier-2's live job. Stop one hand; let the owner drive.
4. **Applies:** Rule 4 (single controller). `templates/monitor.md` discipline section.

---

### Batch `claude -p` sub-work hit rate limits / drained the subscription window
1. **Cross-verify:** check for 429/rate-limit lines in the batch log; count how many `claude -p`
   were launched in parallel.
2. **Likely cause:** concurrency too high — many simultaneous headless calls burn the rolling
   subscription window fast and trip rate-limiting.
3. **Fix:** cap concurrency low (≤3), save results incrementally, and make the batch resumable so a
   trip doesn't re-spend on already-done items. Also push batch/cheap work onto a cheaper model tier
   (`--model sonnet`) so token volume sits on the cheap tier (see `references/pacing-and-cost.md`).
4. **Applies:** `templates/driver.md` batch rule (≤3 + incremental-save + resume).

---

### A gate's command produced empty output
1. **Cross-verify:**
   ```bash
   sleep 2; <re-run the exact gate command>     # flush lag? re-run before concluding
   ls -la <expected-output-file>; stat <file>   # did the file actually get written / is it nonempty?
   ```
2. **Likely cause:** flush delay — the producing process hasn't flushed to disk/stdout yet. Empty ≠
   failed.
3. **Fix:** re-run and cross-verify before drawing any conclusion. NEVER fabricate or assume a passing
   gate from empty output; paste the REAL re-run output. If it's genuinely empty after a clean re-run,
   record the failure and diagnose.
4. **Applies:** Rule 5 (integrity guard — empty usually = flush delay). `lib/assert_gate.sh`
   file-nonempty assertion; `templates/driver.md` integrity rules.

---

### An engine crashed right after a "fix"
1. **Cross-verify:** read the crash stack; diff what changed just before it (flag/env/config the last
   cycle set).
2. **Likely cause:** a stack-incompatible "fix" — a memory/perf flag that crashes that specific engine
   (e.g. vLLM + `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`), or a host-namespace orphan you
   tried to kill from inside a container.
3. **Fix:** revert the incompatible flag. Then RECORD it as a dead end in `templates/driver.md`
   environment hard-rules AND in the cross-run `scars.md` ("never set X with engine Y"), so the next
   cycle / next run stops re-trying it. The point of scars is that the brain never re-discovers the
   same crash.
4. **Applies:** Rule 8 (know your stack's incompatible fixes; record them). `templates/driver.md`
   env hard-rules + persisted `scars.md`.

---

> If a symptom isn't here: cross-verify with GPU/PID/tmux first, check `references/hard-rules.md` for
> the governing scar, and append the new symptom + fix to `scars.md` so it's in this runbook next time.
