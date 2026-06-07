#!/usr/bin/env bash
# lib/assert_gate.sh — programmatic gate assertions (the VERIFICATION backbone).
#
# Models fake "done". These checks let a gate pass ONLY on real, machine-checked state, and
# print PASS/FAIL lines you paste straight into STATUS.md as evidence. Each returns/exits 0 on
# PASS, nonzero with a clear message on FAIL. Source the file to call the functions, or run a
# subcommand directly.
#
# The CLI accepts the SAME gate-assert vocabulary used in templates/config.json's `gates[].assert`
# (hyphenated DSL) AND the underscore function names — both map to one implementation, so every
# documented invocation actually runs:
#
#   bash lib/assert_gate.sh file-nonempty  <path>                 # artifact exists AND non-empty
#   bash lib/assert_gate.sh state-changed  <path>                 # file/dir advanced since last check
#   bash lib/assert_gate.sh marker         <file> <token>         # token on its OWN line (^…$) only
#   bash lib/assert_gate.sh metric>=<thr>  <cmd...>               # run cmd, parse a number, >= thr
#   bash lib/assert_gate.sh session-dead   <tmux-name>            # session genuinely gone
#   bash lib/assert_gate.sh no-gpu-orphans <pattern>              # no pool PID still holds a GPU
#   bash lib/assert_gate.sh cmd            <shell...>             # generic: passes iff cmd exits 0
#
# Underscore forms (direct function call shapes) also work as subcommands:
#   file_nonempty <path> | marker_anchored <marker> <file> | changed <statefile> <key> <newval>
#   metric_ge <value> <threshold> | session_dead <name> | no_gpu_orphans <pattern>
#
# NOTE (hard-rule #10): a metric PASS on a TINY eval sample can be noise (≈±11pp at 70 items).
# Size the gate adequately or mark it provisional before concluding from a single assert.
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
# PASS and FAIL both to stdout so a single capture grabs the evidence; the RETURN CODE is the signal.
_pass() { echo "PASS $*"; return 0; }
_fail() { echo "FAIL $*"; return 1; }
_indet(){ echo "INDETERMINATE $*"; return 2; }   # can't verify -> NOT a pass; never bank it as evidence

# our own helper scripts — a controller running one carries the pattern in its argv and would
# self-match (the sentinel-self-match scar); exclude them, our whole ancestor chain, AND our own
# process group (so a transient sibling co-process like the awk below can't match either).
SELF_RE='(healthcheck|launch_worker|sweep_orphans|assert_gate|restart_supervisor)\.sh'
MYPGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
_pidchain() {
  local pid=$$ out=""
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    out="$out $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) break ;; esac
  done
  printf ' %s ' "$out"
}

assert_file_nonempty() {
  local f="${1:?path required}"
  [ -f "$f" ] || { _fail "file_nonempty: $f (missing)"; return 1; }
  local sz; sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  [ "${sz:-0}" -gt 0 ] || { _fail "file_nonempty: $f (0 bytes — flush delay? re-run + cross-verify before concluding)"; return 1; }
  _pass "file_nonempty: $f (${sz} bytes)"
}

# Done-marker discipline: match the marker ONLY as its own line (optionally markdown-decorated).
# A whole-file grep FALSE-COMPLETES the moment the brain merely quotes the marker in a plan.
assert_marker_anchored() {
  local marker="${1:?marker required}" f="${2:?file required}"
  [ -f "$f" ] || { _fail "marker_anchored: $f (missing)"; return 1; }
  if grep -qaE "^[[:space:]>*#-]*${marker}[[:space:]]*\$" "$f" 2>/dev/null; then
    _pass "marker_anchored: '$marker' present as its OWN line in $f"
  else
    _fail "marker_anchored: '$marker' NOT on its own line in $f (a loose mention must not count — anchored ^…\$ only)"
  fi
}

# Proves state actually MOVED: records the prior value for <key>, passes only if <newvalue> differs.
# (Keys must be plain identifiers — they go into an anchored grep.)
assert_changed() {
  local sf="${1:?statefile required}" key="${2:?key required}" new="${3:?newvalue required}"
  local prev=""
  if [ -f "$sf" ]; then
    prev=$(grep -aE "^${key}=" "$sf" 2>/dev/null | tail -1); prev=${prev#"${key}="}
  fi
  # record the new value (replace any prior line for this key)
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/assert_changed.XXXXXX") || { _fail "changed: cannot create tempfile"; return 1; }
  [ -f "$sf" ] && { grep -avE "^${key}=" "$sf" > "$tmp" 2>/dev/null || true; }
  printf '%s=%s\n' "$key" "$new" >> "$tmp"
  mv "$tmp" "$sf"
  if [ -n "$prev" ] && [ "$prev" = "$new" ]; then
    _fail "changed: '$key' did NOT move — still '$new' (state stalled; gate not satisfied)"; return 1
  fi
  _pass "changed: '$key' moved '${prev:-<unset>}' -> '$new'"
}

# state-changed <path>: derive a signature for a file or dir (newest mtime + size/count) and pass
# only if it moved since the last call — the config.json-facing form of assert_changed for "the
# checkpoint advanced" style gates, where you don't have a single scalar to hand.
GATE_STATE="${GATE_STATE:-.assert_gate_state}"
_path_sig() {
  local p="$1" m sz newest count
  [ -e "$p" ] || { echo "MISSING"; return 0; }
  if [ -d "$p" ]; then
    newest=$(find "$p" -type f 2>/dev/null \
             | while IFS= read -r f; do stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null; done \
             | sort -n | tail -1)
    count=$(find "$p" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "${newest:-0}:${count:-0}"
  else
    m=$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null)
    sz=$(wc -c < "$p" 2>/dev/null | tr -d ' ')
    echo "${m:-0}:${sz:-0}"
  fi
}
assert_state_changed() {
  local p="${1:?path required}" key sig
  [ -e "$p" ] || { _fail "state_changed: $p (missing — nothing has been produced yet)"; return 1; }
  key=$(printf 'p_%s' "$p" | tr -c 'A-Za-z0-9' '_')
  sig=$(_path_sig "$p")
  # reuse assert_changed but relabel the evidence as state_changed for clarity
  if assert_changed "$GATE_STATE" "$key" "$sig" >/dev/null; then
    _pass "state_changed: $p advanced (sig=$sig)"
  else
    _fail "state_changed: $p did NOT advance since last check (sig=$sig — no new output; gate not satisfied)"; return 1
  fi
}

assert_metric_ge() {
  local v="${1:?value required}" t="${2:?threshold required}"
  local re='^[+-]?([0-9]+(\.[0-9]+)?|\.[0-9]+)([eE][+-]?[0-9]+)?$'
  [[ "$v" =~ $re ]] || { _fail "metric_ge: value '$v' is not numeric"; return 1; }
  [[ "$t" =~ $re ]] || { _fail "metric_ge: threshold '$t' is not numeric"; return 1; }
  if [ "$(awk -v v="$v" -v t="$t" 'BEGIN{print (v+0>=t+0)?1:0}')" = "1" ]; then
    _pass "metric_ge: $v >= $t"
  else
    _fail "metric_ge: $v < $t (below threshold)"; return 1
  fi
}

# metric>=<thr> <cmd...>: run <cmd>, parse the FIRST number it prints, assert it clears <thr>.
assert_metric_cmd() {
  local thr="${1:?threshold required}"; shift || true
  [ "$#" -gt 0 ] || { _fail "metric>=: no command given to produce the metric"; return 1; }
  local out num
  out=$(bash -c "$*" 2>/dev/null) || true
  num=$(printf '%s' "$out" | grep -oE '[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?' | head -1)
  [ -n "$num" ] || { _fail "metric>=: '$*' printed no parseable number (got: ${out:-<empty>} — flush delay? re-run)"; return 1; }
  assert_metric_ge "$num" "$thr"
}

# cmd <shell...>: generic escape hatch — passes iff the wrapped command exits 0. Lets a gate assert
# anything programmatic (test suite green, endpoint 200, two files diff-clean) without a bespoke mode.
assert_cmd() {
  [ "$#" -gt 0 ] || { _fail "cmd: no command given"; return 1; }
  local rc
  if bash -c "$*"; then _pass "cmd: ($*) exited 0"; else rc=$?; _fail "cmd: ($*) exited $rc"; return 1; fi
}

assert_session_dead() {
  local name="${1:?tmux-name required}"
  if ! have tmux; then _indet "session_dead: '$name' — tmux not installed, cannot verify (NOT a pass; install tmux or use a different check)"; return 2; fi
  if tmux has-session -t "$name" 2>/dev/null; then
    _fail "session_dead: tmux session '$name' is STILL ALIVE (attach: tmux attach -t $name)"; return 1
  fi
  _pass "session_dead: tmux session '$name' is gone"
}

# GPU/PID is ground truth: find pool PIDs via anchored ps+grep (NEVER pkill -f), drop self/parent/grep
# AND our own process group (a transient sibling awk co-process shares it), and — when nvidia-smi
# exists — keep only those that actually still HOLD a GPU.
assert_no_gpu_orphans() {
  local pat="${1:?pattern required}" pids p ex; ex=$(_pidchain)
  pids=$(ps -eo pid=,pgid=,args= 2>/dev/null | grep -E "$pat" | grep -v grep \
         | awk -v ex="$ex" -v self="$SELF_RE" -v mypg="$MYPGID" '
             (mypg!="" && $2==mypg) { next }
             { if (index(ex, " " $1 " ")) next; if ($0 ~ self) next; print $1 }' \
         | paste -sd' ' - || true)
  if have nvidia-smi; then
    local gset hold=""
    gset=" $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ' | grep -E '^[0-9]+$' | paste -sd' ' - || true) "
    for p in $pids; do case "$gset" in *" $p "*) hold="$hold $p" ;; esac; done
    pids="${hold# }"
  fi
  if [ -n "${pids// /}" ]; then
    _fail "no_gpu_orphans: leftover pool PIDs still resident [${pids// /, }] — sweep them (lib/sweep_orphans.sh '$pat' --kill) or the next run OOMs"; return 1
  fi
  _pass "no_gpu_orphans: none match '$pat'"
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    file_nonempty|file-nonempty)     assert_file_nonempty   "$@" ;;
    marker_anchored)                 assert_marker_anchored "$@" ;;                    # <marker> <file>
    marker)                          assert_marker_anchored "${2:?token required}" "${1:?file required}" ;;  # <file> <token>
    changed)                         assert_changed         "$@" ;;
    state_changed|state-changed)     assert_state_changed   "$@" ;;
    metric_ge)                       assert_metric_ge       "$@" ;;
    "metric>="*)                     assert_metric_cmd      "${cmd#metric>=}" "$@" ;;
    session_dead|session-dead)       assert_session_dead    "$@" ;;
    no_gpu_orphans|no-gpu-orphans)   assert_no_gpu_orphans  "$@" ;;
    cmd)                             assert_cmd             "$@" ;;
    *) echo "usage: $0 {file-nonempty|state-changed|marker|metric>=<thr>|session-dead|no-gpu-orphans|cmd} ARGS..." >&2; exit 2 ;;
  esac
  exit $?
fi
