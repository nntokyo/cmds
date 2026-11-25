#!/bin/bash
# Day run: what a day of cmds looks like to its agents, on an isolated instance of this checkout's Debug build with
# the real Claude Code. Checks that schedules and kept instructions reach agents that have been idle for a while
# (5, 30 and 60 minutes: Claude Code's own "waiting for your input" notice comes after one), schedules due in the
# same minute, text a person typed in the input box, an account switch, a restart with sessions resumed and a
# time that passed meanwhile, and a simulated sleep. docs/internals/testing.md "Day run".
#
#   scripts/day-run.sh [--quick] [--account NAME] [--to-account NAME] [--model MODEL] [--keep]
#
# --quick: idle times of 2, 3 and 4 minutes (about 25 minutes in all; the full run takes about 80).
# --account: the Claude account (cmds accounts) the agents run under (default: the first one without a limit);
# --to-account: the account to switch to (default: the next one without a limit; without one the switch is skipped).
# --model: the model the agents start with (`claude --model MODEL`, e.g. haiku: the prompts are one word, and the
# run should not eat into an account's limit); a session resumed after the switch or the restart uses its own.
# The running cmds and its sessions are never touched: only `claude-accounts.json` is copied from it. Each agent
# answers a handful of one-word prompts. The Mac is not put to sleep: the sleep is a moved schedule clock
# (`debug.schedule_clock`), as a wake after it. Results: one PASS/FAIL line per check, in <dir>/results.txt.
# Exit status 1 when a check failed. Build first: xcodebuild -scheme CmdsApp -derivedDataPath build/dd build
set -u

quick=false; keep=false; account=""; to_account=""; model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) quick=true; shift ;;
    --keep) keep=true; shift ;;
    --account) account="$2"; shift 2 ;;
    --to-account) to_account="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    *) echo "usage: $0 [--quick] [--account NAME] [--to-account NAME] [--model MODEL] [--keep]" >&2; exit 2 ;;
  esac
done
if $quick; then G1=2; G2=3; G3=4; else G1=5; G2=30; G3=60; fi
# Longer than Claude Code's idle notice (60 s) before every check that types into an agent.
SETTLE=130

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/dd/Build/Products/Debug/cmds.app"
[ -x "$app/Contents/MacOS/cmds" ] || { echo "no app at $app (build it first)" >&2; exit 1; }
live="$HOME/Library/Application Support/cmds"
[ -f "$live/claude-accounts.json" ] || { echo "no Claude accounts in $live" >&2; exit 1; }

# Short paths: the instance's Unix socket lives in the support folder.
base="${CMDS_DAY_RUN_DIR:-${TMPDIR:-/tmp}}"; base="${base%/}"
dir=$(mktemp -d "$base/cmds-day.XXXXXX")
# The agents' folder has a fixed name: Claude Code asks its trust question for it once per account, not on every run.
support="$dir/s"; work="$base/cmds-day-work"; $quick && work="$work-quick"; results="$dir/results.txt"; log="$dir/log.txt"
mkdir -p "$support" "$work"; chmod 700 "$support"
cp "$live/claude-accounts.json" "$support/"; chmod 600 "$support/claude-accounts.json"
: > "$results"

cli() { env -u CMDS_PANE_ID -u CMDS_WORKSPACE_ID -u CMDS_SOCKET_PATH CMDS_SUPPORT_DIR="$support" "$app/Contents/Resources/bin/cmds" "$@"; }
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$log"; }
pass() { echo "PASS  $1  $2" >> "$results"; say "PASS  $1  $2"; }
fail() { echo "FAIL  $1  $2" >> "$results"; say "FAIL  $1  $2"; }
nap() { local n=0; while [ "$n" -lt "$1" ]; do sleep 1; n=$((n + 1)); done; }
# Seconds since the epoch of a local "HH:MM" today (or tomorrow when it has passed); minutes ahead as "HH:MM".
ahead() { date -v+"$1"M +%H:%M; }
until_time() { while [ "$(date +%s)" -lt "$1" ]; do sleep 2; done; }

launch() {
  # A clean environment: agents started in the instance must save their transcripts (no parent session variables).
  ( cd / && env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" SHELL="${SHELL:-/bin/zsh}" PATH="$PATH" \
      TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}" CMDS_AGENT_RESUME=always CMDS_SUPPORT_DIR="$support" \
      CMDS_SYNC_DISABLED=1 "$app/Contents/MacOS/cmds" >/dev/null 2>&1 & )
  local n=0
  until cli ping >/dev/null 2>&1; do n=$((n + 1)); [ "$n" -gt 40 ] && { say "the instance did not start"; return 1; }; sleep 1; done
}
stop_instance() {
  local pid n=0
  pid=$(cli identify 2>/dev/null | sed -n 's/.* pid \([0-9]*\) .*/\1/p')
  cli quit >/dev/null 2>&1
  # Only ever this instance: its pid as it reported it on its own socket.
  while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do n=$((n + 1)); [ "$n" -gt 20 ] && { kill "$pid" 2>/dev/null; break; }; sleep 1; done
}
cleanup() {
  stop_instance
  if ! $keep && [ "${dir#"$base"/cmds-day.}" != "$dir" ]; then rm -rf "$support" "$work"; fi
}
trap cleanup EXIT

# The terminal pane of the workspace titled $1 (ids change when the instance restarts).
pane_of() {
  cli ls --json | python3 -c '
import json, sys
for w in json.load(sys.stdin):
    if w.get("title") == sys.argv[1]:
        print(next(p["id"] for p in w["panes"] if p["kind"] == "terminal")); break' "$1"
}
# The pane's visible text without its empty rows (the rows below the agent's input box are empty).
screen() { cli read --pane "$1" 2>/dev/null | grep -v '^[[:space:]]*$'; }
# Accounts without a recorded limit, in the switching order.
free_accounts() {
  python3 -c '
import json, sys, time
data = json.load(open(sys.argv[1]))
for a in (data.get("accounts", data) if isinstance(data, dict) else data):
    limit = a.get("limit")
    if not limit: print(a["name"])' "$support/claude-accounts.json"
}
# Claude Code is at its input box in pane $1 (answers the folder trust question as a person would: Yes).
wait_prompt() {
  local n=0 text
  while [ "$n" -lt 90 ]; do
    text=$(screen "$1" | tail -12)
    if echo "$text" | grep -q "Enter to confirm" && echo "$text" | grep -q "Yes, I trust"; then
      # The dialog has drawn; move to Yes, and press Return only when Yes is the marked choice.
      nap 2
      if ! screen "$1" | tail -12 | grep -q "❯ Yes, I trust"; then printf '\033[B' | cli send --pane "$1" - ; nap 1; fi
      if screen "$1" | tail -12 | grep -q "❯ Yes, I trust"; then printf '\r' | cli send --pane "$1" - ; nap 3; fi
    elif echo "$text" | grep -q "^❯" && echo "$text" | grep -q "────"; then
      return 0
    fi
    n=$((n + 1)); sleep 1
  done
  return 1
}
# Waits until pane $1 shows the reply $2 (at most $3 s).
wait_reply() {
  local n=0
  while [ "$n" -lt "$3" ]; do screen "$1" | grep -q "⏺ $2" && return 0; n=$((n + 3)); sleep 3; done
  return 1
}
# The last history line of the schedule named $1 once its run ended (at most $2 s); empty when it did not.
run_end() {
  local n=0 line
  while [ "$n" -lt "$2" ]; do
    line=$(cli schedule history --limit 100 | grep "  $1  " | head -1)
    case "$line" in *succeeded*|*skipped*|*failed*|*missed*|*cancelled*) echo "$line"; return 0 ;; esac
    n=$((n + 3)); sleep 3
  done
  return 1
}
# The outcome of the kept instruction $1 once it left the queue (at most $2 s).
queue_end() {
  local n=0 line
  while [ "$n" -lt "$2" ]; do
    line=$(cli queue list | grep "^  $1  " | head -1)
    [ -n "$line" ] && { echo "$line" | awk '{print $3}'; return 0; }
    n=$((n + 3)); sleep 3
  done
  return 1
}
# The four workspaces are still there: the instance's window is on the screen, and whoever uses the Mac can close it.
intact() {
  [ "$(cli ls --json 2>/dev/null | python3 -c 'import json,sys; print(sum(1 for w in json.load(sys.stdin) if (w.get("title") or "").startswith("day")))' 2>/dev/null)" = 4 ]
}
guard() {
  intact && return 0
  fail "$1" "the instance's workspaces were closed from outside the run; the checks after this are not made"
  echo; echo "$(grep -c '^PASS' "$results") passed, $(grep -c '^FAIL' "$results") failed, stopped early  ($results)"; cat "$results"
  exit 1
}
idle_of() { cli idle --minutes 1 | grep "^$1 " | sed -E 's/^[^ ]+  [^ ]+  [^ ]+  //'; }
ask() { echo "Reply with only the word $1 and do nothing else."; }
# check_run NAME WORD PANE LABEL [TIMEOUT]: the schedule's run succeeded and the agent answered.
check_run() {
  local line; line=$(run_end "$1" "${5:-240}")
  if echo "$line" | grep -q succeeded && wait_reply "$3" "$2" 60; then pass "$4" "${6:-}${line##*  $1  }"; else fail "$4" "${6:-}${line:-the run did not end}"; fi
}
check_queue() {
  local outcome; outcome=$(queue_end "$1" "${5:-240}")
  if [ "$outcome" = delivered ] && wait_reply "$3" "$2" 60; then pass "$4" "${6:-}delivered"; else fail "$4" "${6:-}${outcome:-still waiting: $(cli queue list | grep "^$1" | cut -c1-120)}"; fi
}

main() {
# --- Setup ---------------------------------------------------------------------------------------------------------
say "day run in $dir (idle times $G1, $G2, $G3 min)"
launch || exit 1
[ -n "$account" ] || account=$(free_accounts | sed -n 1p)
[ -n "$to_account" ] || to_account=$(free_accounts | grep -vx "$account" | sed -n 1p)
[ -n "$account" ] || { say "no Claude account without a limit"; exit 1; }
say "cmds $(cli identify | awk '{print $2}'), account $account, switch to ${to_account:-(none: skipped)}"
for title in dayA dayB dayC dayD; do
  cli new --title "$title" --cwd "$work" --account "$account" >/dev/null
  pane=$(pane_of "$title")
  if [ -n "$model" ]; then cli send --pane "$pane" --enter "claude --model $model"; else cli send --pane "$pane" --enter claude; fi
done
for title in dayA dayB dayC dayD; do
  pane=$(pane_of "$title")
  wait_prompt "$pane" || { fail setup "Claude Code did not start in $title"; exit 1; }
  cli send --pane "$pane" --enter "$(ask START)"
done
for title in dayA dayB dayC dayD; do wait_reply "$(pane_of "$title")" START 90 || { fail setup "no first answer in $title"; exit 1; }; done
A=$(pane_of dayA); B=$(pane_of dayB); C=$(pane_of dayC); D=$(pane_of dayD)
T0=$(date +%s)
say "four agents answered once: $A $B $C $D"

# --- Idle for G1, G2, G3 minutes: a schedule and a kept instruction each -----------------------------------------
# Schedules fire on the minute, so the idle time is G minutes and up to a minute more.
cli schedule add --name "S$G1" --at "$(ahead $((G1 + 1)))" --send "$(ask "S${G1}OK")" --to agent --pane "$A" --no-warn >/dev/null
cli schedule add --name "S$G2" --at "$(ahead $((G2 + 1)))" --send "$(ask "S${G2}OK")" --to agent --pane "$B" --no-warn >/dev/null
cli schedule add --name "S$G3" --at "$(ahead $((G3 + 1)))" --send "$(ask "S${G3}OK")" --to agent --pane "$D" --no-warn >/dev/null
# Kept instructions are added by hand at their time: Q<G1> to A after its schedule's turn, Q<G2> to B likewise,
# Q<G3> to C, which has done nothing since its first answer.
(
  until_time $((T0 + (2 * G1 + 2) * 60))
  echo "A before Q$G1: $(idle_of "$A")" >> "$log"
  cli queue add --pane "$A" "$(ask "Q${G1}OK")" | awk '{print $1}' > "$dir/q1"
) &
(
  until_time $((T0 + (2 * G2 + 2) * 60))
  echo "B before Q$G2: $(idle_of "$B")" >> "$log"
  cli queue add --pane "$B" "$(ask "Q${G2}OK")" | awk '{print $1}' > "$dir/q2"
) &
(
  until_time $((T0 + G3 * 60))
  echo "C before Q$G3: $(idle_of "$C")" >> "$log"
  cli queue add --pane "$C" "$(ask "Q${G3}OK")" | awk '{print $1}' > "$dir/q3"
) &
for pair in "$G1:$A:A" "$G2:$B:B" "$G3:$D:D"; do
  ( g=${pair%%:*}; rest=${pair#*:}; until_time $(( (T0 / 60 + g + 1) * 60 - 20 )); echo "${rest#*:} before S$g: $(idle_of "${rest%%:*}")" >> "$log" ) &
done

until_time $((T0 + (G1 + 1) * 60))
check_run "S$G1" "S${G1}OK" "$A" "schedule after $G1 min idle"
until_time $((T0 + (2 * G1 + 2) * 60 + 5))
check_queue "$(cat "$dir/q1")" "Q${G1}OK" "$A" "kept instruction after $G1 min idle"

guard "before the pane A checks"
# --- Pane A, each after $SETTLE s of idleness ---------------------------------------------------------------------
# Three schedules due in the same minute.
nap $SETTLE
at=$(ahead 2)
for i in 1 2 3; do cli schedule add --name "SAME$i" --at "$at" --send "$(ask "SAME${i}OK")" --to agent --pane "$A" --no-warn >/dev/null; done
ok=true; detail=""
for i in 1 2 3; do
  line=$(run_end "SAME$i" 300); echo "$line" | grep -q succeeded || ok=false
  detail="$detail SAME$i:$(echo "$line" | grep -oE 'succeeded|skipped[^w]*|failed[^w]*|missed' | head -1)"
done
wait_reply "$A" SAME3OK 90
order=$(screen "$A" | grep -oE "⏺ SAME[123]OK" | tr -d '⏺ ' | tr '\n' ' ')
if $ok && [ "$order" = "SAME1OK SAME2OK SAME3OK " ]; then pass "three schedules in the same minute" "in order:$detail"; else fail "three schedules in the same minute" "$detail; answers: $order"; fi

guard "before the typed text check"
# Text a person typed in the input box: nothing is typed until it is gone, and it is never sent.
nap $SETTLE
cli send --pane "$A" "person-half-typed-words"
nap 3
typed_q=$(cli queue add --pane "$A" "$(ask TYPEDQOK)" | awk '{print $1}')
cli schedule add --name TYPEDS --at "$(ahead 1)" --send "$(ask TYPEDSOK)" --to agent --pane "$A" --no-warn >/dev/null
nap 150
# Held by the typed text, or (once the schedule's run waits in the pane) by that run.
held_q=$(cli queue list | grep "^$typed_q" | grep -c "waits:")
held_s=$(cli schedule history --limit 100 | grep "  TYPEDS  " | head -1 | grep -c "waitingForAgent")
still=$(screen "$A" | grep -c "person-half-typed-words")
if [ "$held_q" = 1 ] && [ "$held_s" = 1 ] && [ "$still" = 1 ]; then pass "typed text holds a schedule and a kept instruction" "both waited 150 s, the text stayed in the box"; else fail "typed text holds a schedule and a kept instruction" "queue held $held_q, run waiting $held_s, text in box $still"; fi
printf '\025' | cli send --pane "$A" -
check_run TYPEDS TYPEDSOK "$A" "schedule after the typed text was cleared"
check_queue "$typed_q" TYPEDQOK "$A" "kept instruction after the typed text was cleared"
sent=$(screen "$A" | grep -c "person-half-typed-words")
if [ "$sent" = 0 ]; then pass "the person's text was not sent" "it appears nowhere in the pane"; else fail "the person's text was not sent" "found $sent times in the pane"; fi

guard "before the account switch"
# An account switch: the schedule made before it and an instruction kept after it reach the session under the
# other account, both after the agent has been idle again.
if [ -n "$to_account" ]; then
  nap $SETTLE
  cli schedule add --name SWITCHS --at "$(ahead 6)" --send "$(ask SWITCHSOK)" --to agent --pane "$A" --no-warn >/dev/null
  switched=$(cli accounts switch --pane "$A" --to "$to_account" 2>&1 | tail -1)
  # The other account may ask the folder trust question first: left alone for $SETTLE s, then answered as a person.
  n=0; asked=false
  while [ "$n" -lt 40 ]; do screen "$A" | tail -12 | grep -q "Enter to confirm" && { asked=true; break; }; screen "$A" | tail -12 | grep -q "^❯" && cli ls | grep -A1 " dayA " | grep -q "account $to_account" && [ "$n" -gt 15 ] && break; n=$((n + 1)); sleep 1; done
  if $asked; then
    nap $SETTLE
    if screen "$A" | tail -12 | grep -q "Enter to confirm"; then pass "the trust question after the switch is left alone" "untouched for $SETTLE s"; else fail "the trust question after the switch is left alone" "it was answered or gone"; fi
  fi
  if wait_prompt "$A" && cli ls | grep -A1 " dayA " | grep -q "account $to_account"; then pass "account switch" "$account → $switched"; else fail "account switch" "$switched; $(cli ls | grep -A1 ' dayA ' | tail -1 | cut -c1-100)"; fi
  check_run SWITCHS SWITCHSOK "$A" "schedule after the account switch" 420
  nap $SETTLE
  switch_q=$(cli queue add --pane "$A" "$(ask SWITCHQOK)" | awk '{print $1}')
  check_queue "$switch_q" SWITCHQOK "$A" "kept instruction after the account switch"
else
  say "no second account without a limit: the account switch is skipped"
fi

guard "before the long idle times"
# --- The long idle times ------------------------------------------------------------------------------------------
until_time $((T0 + (G2 + 1) * 60))
check_run "S$G2" "S${G2}OK" "$B" "schedule after $G2 min idle"
until_time $((T0 + (2 * G2 + 2) * 60 + 5))
check_queue "$(cat "$dir/q2")" "Q${G2}OK" "$B" "kept instruction after $G2 min idle"
until_time $((T0 + G3 * 60 + 5))
check_queue "$(cat "$dir/q3")" "Q${G3}OK" "$C" "kept instruction after $G3 min idle"
until_time $((T0 + (G3 + 1) * 60))
check_run "S$G3" "S${G3}OK" "$D" "schedule after $G3 min idle"
wait
grep -h "before" "$log" | while read -r line; do say "idle time seen: $line"; done

guard "before the restart"
# --- A restart: sessions resumed, a time that passed meanwhile, an instruction kept across it ---------------------
nap $SETTLE
cli send --pane "$C" "words-in-the-box-at-quit"
nap 3
kept=$(cli queue add --pane "$C" "$(ask KEPTOK)" | awk '{print $1}')
# Not in the last seconds of a minute: the schedules must not fire before the instance is stopped.
while [ "$(date +%S)" -gt 35 ]; do sleep 1; done
cli schedule add --name PASSED --at "$(ahead 1)" --send "$(ask PASSEDOK)" --to agent --pane "$D" --no-warn >/dev/null
cli schedule add --name PASSEDSKIP --at "$(ahead 1)" --late skip --send "$(ask WRONG)" --to agent --pane "$D" --no-warn >/dev/null
due=$(( ($(date +%s) / 60 + 1) * 60 ))
stop_instance
say "the instance is stopped until 3 minutes after the schedules' time"
until_time $((due + 180))
launch || { fail restart "the instance did not start again"; exit 1; }
nap 8
resumed=0
n=0
while [ "$n" -lt 60 ]; do
  resumed=$(cli ls --json | python3 -c 'import json,sys; print(sum(1 for w in json.load(sys.stdin) if (w.get("title") or "").startswith("day") for p in w["panes"] if p.get("agent")))')
  [ "$resumed" = 4 ] && break; n=$((n + 3)); sleep 3
done
A=$(pane_of dayA); B=$(pane_of dayB); C=$(pane_of dayC); D=$(pane_of dayD)
if [ "$resumed" = 4 ]; then pass "sessions resumed after the restart" "4 of 4"; else fail "sessions resumed after the restart" "$resumed of 4"; fi
line=$(run_end PASSED 420)
if echo "$line" | grep -q "catch-up.*succeeded" && wait_reply "$D" PASSEDOK 60; then pass "a time that passed while cmds was off runs once" "${line##*  PASSED  }"; else fail "a time that passed while cmds was off runs once" "${line:-the run did not end}"; fi
line=$(run_end PASSEDSKIP 60)
if echo "$line" | grep -q missed; then pass "the same with --late skip is only noted" "${line##*  PASSEDSKIP  }"; else fail "the same with --late skip is only noted" "${line:-nothing in the history}"; fi
runs=$(cli schedule history --limit 100 | grep -c "  PASSED  ")
if [ "$runs" = 1 ]; then pass "the passed time ran once, not twice" "1 run in the history"; else fail "the passed time ran once, not twice" "$runs runs"; fi
check_queue "$kept" KEPTOK "$C" "an instruction kept across the restart" 420

guard "before the sleep"
# --- A sleep (the schedule clock moves, as when the Mac wakes) ---------------------------------------------------
nap $SETTLE
cli schedule add --name SLEPT --in 1h --send "$(ask SLEPTOK)" --to agent --pane "$B" --no-warn >/dev/null
cli schedule add --name SLEPTSKIP --in 1h --late skip --send "$(ask WRONG)" --to agent --pane "$B" --no-warn >/dev/null
cli rpc debug.schedule_clock '{"offset": 3720, "wake": true, "capture": true}' >/dev/null
line=$(run_end SLEPT 300)
if echo "$line" | grep -q "catch-up.*succeeded" && wait_reply "$B" SLEPTOK 60; then pass "a time that passed during sleep runs at wake" "${line##*  SLEPT  }"; else fail "a time that passed during sleep runs at wake" "${line:-the run did not end}"; fi
line=$(run_end SLEPTSKIP 60)
if echo "$line" | grep -q missed; then pass "the same with --late skip is only noted at wake" "${line##*  SLEPTSKIP  }"; else fail "the same with --late skip is only noted at wake" "${line:-nothing in the history}"; fi
cli rpc debug.schedule_clock '{"offset": 0}' >/dev/null

guard "at the end"
# --- Result -------------------------------------------------------------------------------------------------------
wrong=0
for pane in "$A" "$B" "$C" "$D"; do wrong=$((wrong + $(screen "$pane" | grep -c "⏺ WRONG"))); done
if [ "$wrong" = 0 ]; then pass "nothing that should not run was typed" "no WRONG answer on any screen"; else fail "nothing that should not run was typed" "$wrong WRONG answers"; fi
cp "$results" "$dir/results-final.txt" 2>/dev/null
echo
echo "$(grep -c '^PASS' "$results") passed, $(grep -c '^FAIL' "$results") failed  ($results)"
cat "$results"
grep -q '^FAIL' "$results" && exit 1
exit 0
}
main
