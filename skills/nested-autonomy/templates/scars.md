# scars — cross-run memory (append-only)

> Copy to `${CLAUDE_PLUGIN_DATA:-./.nested-autonomy}/scars.md` at setup (the brain reads it every
> cycle and inherits these as Environment hard-rules). Append a line ONLY when a dead-end is
> CONFIRMED (reproduced — not merely suspected), so future runs and the brain stop re-trying it.
>
> One line each — format:  `- <stack/flag/op>: <what fails> → <use instead>`
>
> Seed examples (delete or keep; replace with YOUR stack's verified scars):
- vLLM + `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`: engine crashes on start → don't set it for vLLM.
- worker pool (Ray/torchrun/vLLM) after exit: leaves GPU-holding orphans → `lib/sweep_orphans.sh <pat> --kill` before the next run or it OOMs.
- host-namespace orphan PID inside a container: can't be killed from inside → flag the host; don't burn cycles retrying `kill`.
