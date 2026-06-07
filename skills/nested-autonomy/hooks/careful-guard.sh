#!/usr/bin/env bash
# careful-guard.sh — PreToolUse backstop for UNATTENDED nested-autonomy runs.
#
# This skill runs `claude -p --dangerously-skip-permissions`, i.e. NO human in the
# permission loop on Tier-2/3. This hook is the last line of defense: it inspects every
# Bash command BEFORE it runs and DENIES a small, high-confidence catastrophic denylist.
# Everything else is allowed (silent exit 0) — false-allow beats false-deny here because a
# human still supervises Tier-1; but the unambiguous account-enders are never let through.
#
# Contract (code.claude.com/docs/en/hooks, PreToolUse):
#   stdin  : {"tool_name":"Bash","tool_input":{"command":"..."}, "cwd":..., ...}
#   DENY   : exit 0 + print to stdout
#            {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                                   "permissionDecision":"deny",
#                                   "permissionDecisionReason":"..."}}
#   ALLOW  : exit 0, no stdout (tool proceeds normally)
# (exit 2 + stderr is the older block path; we use the structured permissionDecision form.)
#
# Session-scoped / on-demand: wire it in settings.json only while launching an unattended
# run (the article's `/careful`); remove it for normal interactive work. See hooks/README.md.
#
# Honors THIS skill's own rules: anchored regex (sentinels self-match), ps->kill <pid> never
# pkill -f, GPU/PID is ground truth. Source-able (defines functions) AND runnable (reads stdin).
set -uo pipefail

# ---- config (override via env when wiring the hook) -------------------------------------
SELF_SESSION="${GUARD_SELF_SESSION:-${SELF_TMUX:-driver}}"        # supervisor's OWN tmux session
SELF_PATTERN="${GUARD_SELF_PATTERN:-supervisor|driver|monitor|claude}"  # self-referential kill targets

# ---- output helpers ---------------------------------------------------------------------
json_str() {                                # JSON-encode $1 (jq if present, else minimal escape)
  if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -Rs .
  else local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; printf '"%s"' "$s"; fi
}
deny() {                                    # emit the documented PreToolUse deny + a human log line
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(json_str "careful-guard blocked a catastrophic command: $1")"
  printf 'careful-guard DENY: %s\n' "$1" >&2
  exit 0
}

# ---- match helpers (dynamic scope: see $scrub / $raw set by classify) --------------------
hit()   { printf '%s' "$scrub" | grep -Eiq -- "$1"; }   # case-insensitive, on quote-stripped cmd
hit_cs(){ printf '%s' "$raw"   | grep -Eq  -- "$1"; }    # case-sensitive, on the raw cmd (fork bomb)

# ---- classify: echo a reason + return 0 if catastrophic; else return 1 ------------------
classify() {
  local raw norm scrub
  raw="$1"
  norm="$(printf '%s' "$raw" | tr '\n\t' '  ' | tr -s ' ')"   # one line, collapsed whitespace
  scrub="${norm//\"/}"; scrub="${scrub//\'/}"; scrub="${scrub//\`/}"  # drop quotes -> clean boundaries

  # 1) rm -rf targeting / ~ $HOME or a bare top-level system dir (NOT /tmp/build, ./logs, $HOME/.cache)
  local RMFLAGS='(^|[[:space:]])rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*f|-[[:alnum:]]*f[[:alnum:]]*r|(-r|-R|--recursive)([[:space:]]+-+[[:alnum:]=-]+)*[[:space:]]+(-f|--force)|(-f|--force)([[:space:]]+-+[[:alnum:]=-]+)*[[:space:]]+(-r|-R|--recursive))'
  local TGT_ROOT='(^|[[:space:]])/(\*)?([[:space:]]|[;|&]|$)'
  local TGT_HOME='(^|[[:space:]])(~|\$\{?HOME\}?)(/\*?)?([[:space:]]|[;|&]|$)'
  local TGT_SYS='(^|[[:space:]])/(usr|etc|var|bin|lib|lib64|boot|root|sys|proc|dev|sbin|opt|home)(/\*?)?([[:space:]]|[;|&]|$)'
  if hit "$RMFLAGS" && { hit "$TGT_ROOT" || hit "$TGT_HOME" || hit "$TGT_SYS"; }; then
    echo "recursive-force rm targeting / ~ \$HOME or a top-level system dir"; return 0
  fi

  # 2) forced update of a protected branch: an explicit --force/-f push to a protected ref, a bare
  #    force push, OR a leading '+' refspec (which force-updates the ref with NO flag). Plain push
  #    is fine. The protected word must be a COMPLETE ref arg (right boundary = space/colon/end) so
  #    feature/main-port and release/2026-06 are NOT mistaken for the bare main/release branch.
  local PUSH='(^|[[:space:]])git[[:space:]]+push([[:space:]]|$)'
  local FORCE='(--force(-with-lease)?([[:space:]]|=|$)|(^|[[:space:]])-f([[:space:]]|$))'
  local PROT='(^|[[:space:]/:+])(main|master|prod|production|release|develop|trunk)([[:space:]:]|$)'
  local REFSPEC_FORCE='(^|[[:space:]])\+[^[:space:]]*(main|master|prod|production|release|develop|trunk)([[:space:]]|$)'
  local BARE_FORCE='(^|[[:space:]])git[[:space:]]+push([[:space:]]+[^[:space:]-][^[:space:]]*)?[[:space:]]+(--force(-with-lease)?|-f)[[:space:]]*$'
  if { hit "$PUSH" && { { hit "$FORCE" && hit "$PROT"; } || hit "$REFSPEC_FORCE"; }; } || hit "$BARE_FORCE"; then
    echo "forced git push to a protected branch (--force/-f or +refspec)"; return 0
  fi

  # 3) destructive SQL  (DROP DATABASE/TABLE/SCHEMA, TRUNCATE TABLE — not coreutils `truncate -s`)
  local SQL='(^|[^[:alnum:]_])(drop[[:space:]]+(database|table|schema)|truncate[[:space:]]+table)([^[:alnum:]_]|$)'
  if hit "$SQL"; then echo "destructive SQL (DROP/TRUNCATE)"; return 0; fi

  # 4) kubectl delete — the cluster-mutating form (`kubectl delete <resource>`, always followed by a
  #    space). Right boundary = space/end so local-only `kubectl config delete-context|-cluster|-user`
  #    (which touch no cluster) are NOT blocked.
  if hit '(^|[[:space:]])kubectl[[:space:]][^;|&]*delete([[:space:]]|$)'; then
    echo "kubectl delete"; return 0
  fi

  # 5) mkfs (formats a filesystem)
  if hit '(^|[[:space:]])mkfs(\.[[:alnum:]]+)?([[:space:]]|$)'; then echo "mkfs (filesystem format)"; return 0; fi

  # 6) dd writing to a raw device
  if hit '(^|[[:space:]])dd[[:space:]][^;|&]*of=/dev/'; then echo "dd of=/dev/* (raw device overwrite)"; return 0; fi

  # 7) fork bomb  :(){ :|:& };:   (match on the RAW command — special chars, no quote stripping)
  if hit_cs ':[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}[[:space:]]*;[[:space:]]*:'; then
    echo "fork bomb"; return 0
  fi

  # 8) pkill -f / killall matching the supervisor|driver|monitor|claude pattern (SELF-MATCH RISK).
  #    The scar: `pkill -f <pat>` kills the very script that contains <pat>. Use ps -> kill <pid>.
  if { hit '(^|[[:space:]])pkill[[:space:]][^;|&]*(-f|--full)([[:space:]]|$)' \
       || hit '(^|[[:space:]])killall([[:space:]]|$)'; } && hit "$SELF_PATTERN"; then
    echo "pkill -f / killall matching the supervisor/driver/claude pattern (self-match risk — use ps then kill <pid>)"; return 0
  fi

  # 9) tmux killing its OWN session, or the whole server (would take down the supervisor itself)
  if hit '(^|[[:space:]])tmux[[:space:]]+kill-server([[:space:]]|$)'; then echo "tmux kill-server (kills the supervisor too)"; return 0; fi
  if hit "(^|[[:space:]])tmux[[:space:]]+kill-session[^;|&]*-t[=[:space:]]*${SELF_SESSION}([[:space:]]|[;|&]|$)"; then
    echo "tmux kill-session on the supervisor's own session '${SELF_SESSION}'"; return 0
  fi

  return 1
}

# ---- entry points -----------------------------------------------------------------------
main() {
  local input tool cmd reason
  input="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    tool="$(printf '%s' "$input" | jq -r '.tool_name // empty'          2>/dev/null)"
    cmd="$( printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  else
    # grep/sed fallback (best-effort) when jq is unavailable
    tool="$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')"
    cmd="$( printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n1 | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    cmd="${cmd//\\\"/\"}"; cmd="${cmd//\\n/ }"; cmd="${cmd//\\t/ }"; cmd="${cmd//\\\\/\\}"
  fi
  [ "$tool" = "Bash" ] || exit 0           # only guard Bash; everything else passes through
  [ -n "$cmd" ]        || exit 0
  if reason="$(classify "$cmd")"; then deny "$reason"; fi
  exit 0                                    # allow: silent
}

selftest() {                                # programmatic verification — `careful-guard.sh --selftest`
  local fails=0 r
  check() { # $1 = expect (deny|allow), $2 = command
    if r="$(classify "$2")"; then [ "$1" = deny ] || { printf 'FAIL want=allow got=deny  : %s  (%s)\n' "$2" "$r"; fails=$((fails+1)); return; }
    else [ "$1" = allow ] || { printf 'FAIL want=deny  got=allow : %s\n' "$2"; fails=$((fails+1)); return; }; fi
    printf 'ok  %-5s : %s\n' "$1" "$2"
  }
  # MUST DENY
  check deny 'rm -rf /'
  check deny 'sudo rm -rf /*'
  check deny 'rm -rf ~'
  check deny 'rm -rf $HOME'
  check deny 'rm -rf "${HOME}"/'
  check deny 'rm -fr /etc'
  check deny 'rm --recursive --force /var'
  check deny 'git push --force origin main'
  check deny 'git push -f'
  check deny 'git push origin master --force-with-lease'
  check deny 'git push origin +main'
  check deny 'git push origin +HEAD:master'
  check deny 'psql -c "DROP TABLE users"'
  check deny 'mysql -e "TRUNCATE TABLE events;"'
  check deny 'DROP DATABASE prod'
  check deny 'kubectl delete deploy api'
  check deny 'kubectl --context prod delete ns app'
  check deny 'mkfs.ext4 /dev/sda1'
  check deny 'dd if=/dev/zero of=/dev/sda bs=1M'
  check deny ':(){ :|:& };:'
  check deny 'pkill -f supervisor.sh'
  check deny 'killall claude'
  check deny 'tmux kill-server'
  check deny 'tmux kill-session -t driver'
  # MUST ALLOW (the skill's own legitimate ops)
  check allow 'kill 48213'
  check allow 'kill -9 48213'
  check allow 'tmux new-session -d -s driver "bash supervisor.sh"'
  check allow 'tmux ls'
  check allow 'tmux has-session -t driver'
  check allow 'tmux kill-session -t train-worker'
  check allow 'claude -p "$(cat prompts/driver.md)" --dangerously-skip-permissions'
  check allow 'git commit -m "gate passed"'
  check allow 'git push origin feature/data-ablation'
  check allow 'git push --force origin feature/main-port'
  check allow 'git push --force-with-lease origin release/2026-06'
  check allow 'git push -f origin develop-experiment'
  check allow 'kubectl config delete-context prod'
  check allow 'kubectl config delete-cluster staging'
  check allow 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader'
  check allow 'ps aux | grep python'
  check allow 'setsid nohup python train.py </dev/null >train.log 2>&1 &'
  check allow 'rm -rf /tmp/build'
  check allow 'rm -rf ./logs'
  check allow 'rm -rf $HOME/.cache/torch'
  check allow 'truncate -s 0 logs/driver.log'
  check allow 'pkill -f tensorboard'
  echo "----"
  if [ "$fails" -eq 0 ]; then echo "selftest PASS"; else echo "selftest FAIL ($fails)"; fi
  return "$fails"
}

# Run default action only when executed directly; sourcing just loads the functions.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  case "${1:-}" in
    --selftest) selftest ;;
    *) main ;;
  esac
fi
