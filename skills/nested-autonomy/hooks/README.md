# careful-guard — on-demand safety backstop for unattended runs

This skill drives Tier-2/3 with `claude -p --dangerously-skip-permissions`: there is **no
human in the permission loop** while the supervisor loops for hours. `careful-guard.sh` is a
`PreToolUse` hook that inspects every Bash command first and **denies a small, high-confidence
catastrophic denylist** — the backstop for the moment the brain hallucinates an account-ender.

It is the nested-autonomy analogue of the article's **`/careful`**: a guard you switch ON for an
unattended run and OFF for normal work. (A future **`/freeze`** is sketched at the bottom.)

## Wire it (settings.json)

Add to the settings.json that governs the unattended run (project `.claude/settings.json`, or the
`--settings` file you pass to the headless brain). Matcher is `Bash`; point at the hook:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/skills/nested-autonomy/hooks/careful-guard.sh"
          }
        ]
      }
    ]
  }
}
```

Use an absolute path if `${CLAUDE_PROJECT_DIR}` is not your repo root. `chmod +x` the script.

**Session-scoped / on-demand.** Enable it when you launch the unattended run; drop it for ordinary
interactive sessions where you approve calls yourself. It is a guard, not a permanent policy.

## How it decides (the documented PreToolUse contract)

Reads the hook JSON on stdin (`tool_name`, `tool_input.command`). On a catastrophic match it
**exits 0 and prints the documented deny object** to stdout:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}
```

Otherwise it stays silent and exits 0 (the tool proceeds). It also echoes a `careful-guard DENY:`
line to stderr for the transcript. Source: <https://code.claude.com/docs/en/hooks>.

## Denylist (deny only on high confidence — false-allow beats false-deny, a human still watches Tier-1)

| Blocked | Example |
| --- | --- |
| recursive-force `rm` of `/`, `~`, `$HOME`, or a bare top-level system dir | `rm -rf /`, `rm -fr /etc`, `rm -rf $HOME` |
| forced `git push` to a protected branch — `--force`/`-f`, a bare force, OR a `+refspec` | `git push --force origin main`, `git push -f`, `git push origin +main` |
| destructive SQL | `DROP DATABASE`, `DROP TABLE`, `TRUNCATE TABLE` |
| `kubectl delete` | `kubectl delete deploy api` |
| `mkfs`, `dd of=/dev/...` | `mkfs.ext4 /dev/sda1`, `dd ... of=/dev/sda` |
| fork bomb | `:(){ :\|:& };:` |
| `pkill -f` / `killall` matching `supervisor\|driver\|monitor\|claude` (self-match scar) | `pkill -f supervisor.sh`, `killall claude` |
| `tmux kill-server`, or `tmux kill-session` on the supervisor's OWN session | `tmux kill-server`, `tmux kill-session -t driver` |

**Deliberately NOT blocked** — the skill's own legitimate ops: `kill <pid>` (numeric),
`tmux new-session/ls/has-session`, `tmux kill-session -t <worker>`, `claude -p ...`,
`git commit`, non-force `git push`, force-push to a *namespaced* branch (`feature/main-port`,
`release/2026-06` — only the bare protected refs are guarded), `kubectl config delete-context`
(local kubeconfig, mutates no cluster), `nvidia-smi`, `ps`, `setsid nohup`, scoped cleanup like
`rm -rf /tmp/build` / `rm -rf $HOME/.cache/...`, and coreutils `truncate -s`.

## Tune & verify

- `GUARD_SELF_SESSION` (default `driver`) — the supervisor's own tmux session name (rule 9).
- `GUARD_SELF_PATTERN` (default `supervisor|driver|monitor|claude`) — names a `pkill -f`/`killall`
  must not match.
- **Run the built-in battery before trusting it** (46 allow/deny assertions):

  ```bash
  ./careful-guard.sh --selftest      # prints each case; exits non-zero on any miss
  ```

- Spot-check the live contract:

  ```bash
  printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | ./careful-guard.sh   # -> deny JSON
  printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | ./careful-guard.sh   # -> silent
  ```

`jq` is used when present; a grep/sed fallback handles a host without it. Anchored regex
throughout (sentinels self-match), `ps -> kill <pid>` never `pkill -f`, GPU/PID is ground truth.

## Known limits (by design — it's a backstop, not a sandbox)

- **It matches the command STRING, not runtime behavior.** It cannot see a variable resolved at
  runtime or inside `eval` (`D=/ ; rm -rf "$D"` reads as benign). Pair it with `/freeze` and real
  OS/permission boundaries (container, scoped user) — never rely on it as the only fence.
- **Quote-scrub trades a false-deny for anti-evasion.** It strips quotes so `rm -rf "/"` can't
  dodge the match; the cost is that a *read-only* command which merely MENTIONS a dangerous phrase
  (e.g. `echo "rm -rf /"`, `grep "drop table" log`) is also denied. This false-deny class is
  recoverable (re-run interactively) and consistent with the "false-allow beats false-deny" stance.

## Future: `/freeze` (filesystem fence)

The same on-demand pattern, for writes instead of shell: a `PreToolUse` hook on
`matcher: "Edit|Write"` that **denies any path outside the project dir** (resolve the target
against `cwd`/`$CLAUDE_PROJECT_DIR`; deny if it escapes). Pair it with `careful-guard` when you
want an unattended run that can neither run a catastrophic shell command nor edit files outside
its sandbox. Not implemented yet — drop it in this folder as `freeze-guard.sh` when needed.
