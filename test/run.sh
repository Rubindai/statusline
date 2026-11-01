#!/usr/bin/env bash
# Test suite for the status line. Hermetic: fake $HOME, stubbed ccusage/npx/bunx, no network.
#
#   bash test/run.sh               # with the bash on PATH
#   bash test/run.sh --bash32      # also re-run the whole suite under bash 3.2 (stock macOS) in Docker
#
# Needs jq and git. Fixtures follow https://code.claude.com/docs/en/statusline; "@NOW+N" strings in
# them become epoch seconds N from now.
# shellcheck disable=SC2016  # checks are eval'd strings, expanded when they run
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
R="$ROOT/statusline-command.sh"
C="$ROOT/cost-refresh.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
ESC=$(printf '\033')
NOW=$(date +%s)
unset FNM_DIR NVM_DIR VOLTA_HOME ASDF_DATA_DIR NODENV_ROOT PNPM_HOME COLUMNS NO_COLOR STATUSLINE_ASCII

pass=0 fail=0
ok()    { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "${OUT:-}${ERR:+
stderr: $ERR}"; fi; }
has()   { case $OUT in *"$1"*) return 0 ;; esac; return 1; }
lacks() { ! has "$1"; }
rows()  { [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq "$1" ]; }
clean() { [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -n "$OUT" ]; }

fixture() {
  jq --argjson now "$NOW" \
    'walk(if type == "string" and startswith("@NOW+") then $now + (ltrimstr("@NOW+") | tonumber) else . end)' \
    "$ROOT/test/fixtures/$1.json"
}
newhome() { H=$(mktemp -d "$T/home.XXXXXX"); mkdir -p "$H/.claude/statusline/cache"; }
run_r() { # run_r <stdin text> [VAR=value ...]  ->  OUT ERR RC   (NO_COLOR and debug stderr by default)
  local in=$1; shift
  printf '%s' "$in" | env HOME="$H" NO_COLOR=1 STATUSLINE_DEBUG=1 "$@" bash "$R" >"$T/out" 2>"$T/err"
  RC=$?; OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
render() { local f=$1; shift; run_r "$(fixture "$f")" "$@"; }   # render <fixture> [VAR=value ...]
fits_in() { # every row of OUT is at most $1 terminal cells (the hourglass is two cells wide)
  local l w h
  while IFS= read -r l; do
    l=$(printf '%s' "$l" | sed "s/${ESC}\[[0-9;]*m//g")
    w=$(printf '%s' "$l" | wc -m); h=$(printf '%s' "$l" | grep -o '⏳' | wc -l)
    [ $(( w + h )) -le "$1" ] || return 1
  done <<<"$OUT"
}
day() { date -d "@$1" +%F 2>/dev/null || date -r "$1" +%F; }
rolling() { echo $(( (NOW - 604800) / 3600 * 3600 )); }
wait_for() { local n=0; while [ "$n" -lt 20 ]; do [ -s "$1" ] && return 0; sleep 0.1; n=$((n + 1)); done; return 1; }
readcache() { t='' w='' at=0 ws='' de=0 p=''; [ -r "$1" ] && read -r t w at ws de p _ <"$1"; OUT="$t $w $at $ws $de $p"; ERR=''; }
ymd8() { date -d "@$1" +%Y%m%d 2>/dev/null || date -r "$1" +%Y%m%d; }

# stubs: ccusage answers only `claude daily` (proving the agent-scoped subcommand is used); npx/bunx fail
S="$T/stubs"; mkdir -p "$S"
cat >"$S/ccusage" <<'EOF'
#!/bin/sh
case "$1" in --version|-v) echo "ccusage 20.0.46"; exit 0 ;; esac
[ "$1 $2" = "claude daily" ] || exit 1
if [ -n "${STUB_LOG:-}" ]; then
  echo "$*" >>"$STUB_LOG"
  command -v ionice >/dev/null 2>&1 && ionice -p $$ >>"$STUB_LOG.io" 2>&1
fi
cat "${STUB_JSON:-/nonexistent}"
EOF
printf '#!/bin/sh\nexit 1\n' >"$S/npx"; cp "$S/npx" "$S/bunx"
chmod +x "$S/ccusage" "$S/npx" "$S/bunx"

echo "bash $BASH_VERSION · $(jq --version) · $(git --version)"

# ---------------------------------------------------------------------------------------------------
echo "renderer: schema coverage"
newhome
render full
check "full schema renders cleanly in three rows" eval 'clean && rows 3'
check "model, effort, fast mode, output style" eval 'has "★ Opus 5.5  ● max · ↯ fast · Explanatory"'
check "context bar carries the 1M window size" eval 'has "Context 1M ▰▰▰▰▱▱▱▱▱▱▱▱ 34%"'
check "5H/7D bars with countdowns" eval 'has "5H ▰▰▱▱▱▱ 41% ⏳2h16m" && has "7D ▰▰▰▱▱▱ 58% ⏳2d1h"'
check "pace = elapsed% - used% (70.8 - 58.4)" eval 'has "pace +12%"'
check "session cost, burn rate, api time, lines" eval 'has "\$4.20 sess" && has "\$6.30/hr" && has "api 18m" && has "+320 −140"'
check "warm prompt cache with hit ratio and expiry" eval 'has "cache 91% ⏳43m"'
check "PR and vim fields are not duplicated (Claude Code shows them)" eval 'lacks "1234" && lacks NORMAL'

render gateway
check "gateway: spend-limit bar with dollars" eval 'clean && has "Spend ▰▰▰▰▱▱ 62% ⏳14d0h · \$314/\$500"'
check "gateway: critical context gets the warning mark" eval 'has "96% ⚠"'
check "gateway: cold cache" eval 'has "cache 42% cold"'
check "gateway: 200k window is not labelled" eval 'has "Context ▰" && lacks "200k"'

render early
check "first render (nulls, no rate limits)" eval 'clean && rows 3 && has "Context ▱▱▱▱▱▱▱▱▱▱▱▱ 0%" && lacks 5H && lacks pace'

render weird
check "strings/floats/past resets/>100% don't leak errors" eval 'clean && has "120% ⚠" && has "⏳now" && lacks "api"'

run_r ''
check "empty stdin still prints" eval 'clean && rows 3'
run_r 'not json' STATUSLINE_DEBUG=
check "invalid JSON still prints, silently" eval 'clean && rows 3'

echo "renderer: output hygiene"
render full NO_COLOR=
check "colored: every row ends with a reset" eval '[ "$(printf "%s\n" "$OUT" | grep -vc "${ESC}\[0m\$")" -eq 0 ]'
check "colored: only SGR escapes are emitted" eval '! printf "%s" "$OUT" | sed "s/${ESC}\[[0-9;]*m//g" | grep -q "$ESC"'
render full
check "NO_COLOR: no escape bytes at all" eval '! printf "%s" "$OUT" | grep -q "$ESC"'
render full STATUSLINE_ASCII=1
check "STATUSLINE_ASCII: pure ASCII" eval '! printf "%s" "$OUT" | LC_ALL=C grep -q "[^ -~]" && has "in 2h16m"'
check "PATH without jq: one-line hint, exit 0" eval 'out=$(echo "{}" | env -i HOME="$H" PATH=/nonexistent "$(command -v bash)" "$R"); [ $? -eq 0 ] && case $out in *"jq not found"*) true ;; *) false ;; esac'

echo "renderer: fitting to \$COLUMNS"
for cols in 100 80 60 40; do
  render full NO_COLOR= COLUMNS=$cols
  check "COLUMNS=$cols: every row fits in $((cols - 4)) cells" eval 'clean && fits_in $((cols - 4))'
done
render full COLUMNS=80
check "narrow: bars shrink before segments are dropped" eval 'has "Context 1M ▰▰▱▱▱▱ 34%" && has "5H ▰▰▱▱ 41%"'
render full COLUMNS=40
check "very narrow: path, context and session cost survive" eval 'has "/home/user/dev/statusline" && has "Context" && has "\$4.20 sess"'
FULL=$(fixture full); START=$(date +%s)
for _ in 1 2 3 4 5 6 7 8 9 10; do run_r "$FULL" NO_COLOR= COLUMNS=120; done
OUT="10 colored, fitted renders took $(( $(date +%s) - START ))s"
check "fast enough for the render path (10 fitted renders < 3s)" eval '[ $(( $(date +%s) - START )) -lt 3 ]'

echo "renderer: git"
G="$T/repo"; git init -q -b main "$G" && git init -q --bare "$T/remote.git"
gc() { git -C "$G" -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }
echo a >"$G/a"; gc add a; gc commit -m one; gc remote add origin "$T/remote.git"; gc push -u origin main
echo b >"$G/b"; gc add b; gc commit -m two; echo dirty >>"$G/a"; echo new >"$G/untracked"
run_r "$(jq -n --arg d "$G" '{workspace: {current_dir: $d}, model: {display_name: "Opus"}}')"
check "branch, ahead count, dirty count (modified + untracked)" eval 'clean && has " main ↑1 ●2"'
gc checkout --detach HEAD~1 2>/dev/null; git -C "$G" stash -q -u 2>/dev/null
run_r "$(jq -n --arg d "$G" '{workspace: {current_dir: $d}}')"
check "detached HEAD shows the short hash" eval "has \" $(git -C "$G" rev-parse --short=7 HEAD)\""
run_r "$(jq -n --arg d "$T" '{workspace: {current_dir: $d}}')"
check "outside a repo: no git segment" eval 'clean && lacks "$(printf "\356\202\240")"'

echo "renderer: cost cache"
newhome
WR=$(fixture full | jq '.rate_limits.seven_day.resets_at')
printf '185.776 2096.33 %s %s %s\n' "$NOW" "$((WR - 604800))" "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
render full
check "today/week from cache; dollars only from \$100" eval 'has "\$4.20 sess · \$186 today · \$2096 week"'
printf '1.5 2.5 %s %s %s\n' "$NOW" 12345 "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
render full
check "week from another weekly cycle is hidden" eval 'has "\$1.50 today" && lacks week'
printf '1.5 2.5 %s %s %s\n' "$NOW" "$((WR - 604800))" "$((NOW - 1))" >"$H/.claude/statusline/cache/cost"
render full
check "today from before midnight is hidden" eval 'lacks today && has "\$2.50 week"'
printf 'x y z\n' >"$H/.claude/statusline/cache/cost"
render full
check "corrupt cache is ignored" eval 'clean && lacks today && lacks week'
printf -- '- - %s %s %s -\n' "$NOW" "$((WR - 604800))" "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
render full
check "'-' (unknown) figures are skipped without errors" eval 'clean && lacks today && lacks week'

echo "renderer: background refresh scheduling"
newhome
printf '#!/bin/sh\necho "$1" >>"%s/spawns"\n' "$H" >"$H/.claude/statusline/cost-refresh.sh"
chmod +x "$H/.claude/statusline/cost-refresh.sh"
printf '1 2 %s %s %s\n' "$NOW" "$(rolling)" "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
render early; render early; render early; sleep 0.5
check "fresh cache, no rate limits: no refresh (rolling window is stable)" eval '[ ! -e "$H/spawns" ]'
printf '1 2 %s %s %s\n' "$((NOW - 301))" "$(rolling)" "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
render early; wait_for "$H/spawns"
check "stale cache: one refresh, passed the window start" eval '[ "$(cat "$H/spawns")" = "$(rolling)" ]'
rm -f "$H/spawns"
printf '1 2 %s %s %s\n' "$NOW" "$(rolling)" "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
render full; wait_for "$H/spawns"
check "rate limits appear: refresh for the 7D cycle start" eval '[ "$(cat "$H/spawns")" = "$((WR - 604800))" ]'

echo "renderer: refresh survives cancellation"
if command -v setsid >/dev/null 2>&1; then
  newhome
  printf '#!/bin/sh\nsleep 1\necho done >"%s/survived"\n' "$H" >"$H/.claude/statusline/cost-refresh.sh"
  chmod +x "$H/.claude/statusline/cost-refresh.sh"
  fixture early >"$T/in.json"
  # the render runs as its own process-group leader; once it has returned, SIGTERM the whole group,
  # the way a cancelled render can be killed
  ( setsid sh -c 'echo $$ >"$1/pg"; exec env HOME="$1" bash "$2" <"$3" >/dev/null 2>&1' _ "$H" "$R" "$T/in.json" )
  kill -TERM -- "-$(cat "$H/pg")" 2>/dev/null; sleep 1.5
  OUT="refresh marker: $(cat "$H/survived" 2>/dev/null)"; ERR=''
  check "the background refresh survives a SIGTERM to the render's process group" eval '[ -s "$H/survived" ]'
else
  echo "  skip  (no setsid here)"
fi

# ---------------------------------------------------------------------------------------------------
echo "cost-refresh"
newhome
CJ="$T/ccusage.json"
jq -n --arg d0 "$(day "$NOW")" --arg d1 "$(day $((NOW - 86400)))" --arg d3 "$(day $((NOW - 3 * 86400)))" \
      --arg d9 "$(day $((NOW - 9 * 86400)))" \
  '{daily: [{date: $d9, totalCost: 100}, {date: $d3, totalCost: 10.5}, {date: $d1, totalCost: 2.25},
            {date: $d0, totalCost: 1.125}], totals: {}}' >"$CJ"
LOG="$T/ccusage.log"
refresh() { env -i HOME="$H" PATH="$S:/usr/local/bin:/usr/bin:/bin" ${TZ:+TZ="$TZ"} STUB_JSON="$1" STUB_LOG="$LOG" bash "$C" "$2"; }
WIN=$((NOW - 3 * 86400))
refresh "$CJ" "$WIN"; RC=$?; readcache "$H/.claude/statusline/cache/cost"
check "sums today and the window from 'ccusage claude daily'" eval '[ "$RC" -eq 0 ] && [ "$t" = 1.125 ] && [ "$w" = 13.875 ] && [ "$ws" = "$WIN" ]'
check "records the next local midnight" eval '[ "$de" -gt "$NOW" ] && [ "$de" -le $((NOW + 90000)) ] && [ "$(date -d "@$de" +%H%M 2>/dev/null || date -r "$de" +%H%M)" = 0000 ]'
OUT=$(cat "$LOG")
check "first run of the day reads the whole window (from a day before its start)" eval '[ "$OUT" = "claude daily --json --since $(ymd8 $((WIN - 86400)))" ] && [ "$p" = 12.75 ]'
jq --arg d0 "$(day "$NOW")" '(.daily[] | select(.date == $d0) | .totalCost) = 2' "$CJ" >"$T/ccusage2.json"
: >"$LOG"; refresh "$T/ccusage2.json" "$WIN"; readcache "$H/.claude/statusline/cache/cost"; OUT="$(cat "$LOG") -> $OUT"
check "later runs read only today; week = cached earlier days + today" eval 'case $OUT in "claude daily --json --since $(ymd8 "$NOW") -> "*) true ;; *) false ;; esac && [ "$t $w $p" = "2 14.75 12.75" ]'
if PATH="/usr/local/bin:/usr/bin:/bin" command -v ionice >/dev/null 2>&1; then
  OUT=$(cat "$LOG.io" 2>/dev/null)
  check "ccusage runs in the idle I/O class" eval 'case $OUT in *idle*) true ;; *) false ;; esac'
fi
printf '5 6 1 %s %s\n' "$WIN" "$((NOW + 3600))" >"$H/.claude/statusline/cache/cost"
refresh /nonexistent "$WIN"; readcache "$H/.claude/statusline/cache/cost"
check "ccusage failure keeps valid figures and records the attempt" eval '[ "$t $w $ws" = "5 6 $WIN" ] && [ "$at" -ge "$NOW" ]'
refresh /nonexistent "$((WIN + 60))"; readcache "$H/.claude/statusline/cache/cost"
check "ccusage failure with a new window drops the old week" eval '[ "$t $w" = "5 -" ]'
echo '{"error": "nope"}' >"$T/bad.json"
refresh "$T/bad.json" "$((WIN + 60))"; OUT=$(cat "$H/.claude/statusline/cache/cost" 2>/dev/null)
check "unexpected JSON shape is rejected" eval 'case $OUT in "5 - "*) true ;; *) false ;; esac'
newhome; mkdir -p "$H/.local/bin" "$T/stubs-nocc"; cp "$S/ccusage" "$H/.local/bin/"; cp "$S/npx" "$S/bunx" "$T/stubs-nocc/"
env -i HOME="$H" PATH="$T/stubs-nocc:/usr/local/bin:/usr/bin:/bin" ${TZ:+TZ="$TZ"} STUB_JSON="$CJ" bash "$C" "$WIN"
readcache "$H/.claude/statusline/cache/cost"
check "finds ccusage under an npm prefix of ~/.local when it isn't on PATH" eval '[ "$t $w" = "1.125 13.875" ]'
# npm global under fnm: the newest Node by version order (v24 > v9) wins, even with v9 sorting later as text
newhome; F="$H/.local/share/fnm/node-versions"
mkdir -p "$F/v9.0.0/installation/bin" "$F/v24.14.0/installation/bin"
cp "$S/ccusage" "$F/v24.14.0/installation/bin/"; cp "$S/npx" "$F/v9.0.0/installation/bin/ccusage"
env -i HOME="$H" PATH="$T/stubs-nocc:/usr/local/bin:/usr/bin:/bin" ${TZ:+TZ="$TZ"} STUB_JSON="$CJ" bash "$C" "$WIN"
readcache "$H/.claude/statusline/cache/cost"
check "finds a global npm install under the newest fnm Node" eval '[ "$t $w" = "1.125 13.875" ]'

# ---------------------------------------------------------------------------------------------------
echo "install / uninstall"
newhome
printf '{"model": "opus", "permissions": {"allow": ["Bash(ls)"]}}\n' >"$H/.claude/settings.json"
printf 'old\n' >"$H/.claude/statusline/cache/cost"
OUT=$(HOME="$H" PATH="$S:$PATH" bash "$ROOT/install.sh" 2>&1); RC=$?; ERR=''
check "install succeeds" eval '[ "$RC" -eq 0 ]'
OUT=$(jq -c '.statusLine' "$H/.claude/settings.json")
check "statusLine uses ~ and refreshInterval 60" eval '[ "$OUT" = "{\"type\":\"command\",\"command\":\"~/.claude/statusline/statusline-command.sh\",\"padding\":0,\"refreshInterval\":60}" ]'
check "other settings are preserved, and backed up" eval '[ "$(jq -c "[.model, .permissions.allow[0]]" "$H/.claude/settings.json")" = "[\"opus\",\"Bash(ls)\"]" ] && ls "$H"/.claude/settings.json.bak.* >/dev/null'
check "scripts installed executable; stale cost cache cleared" eval '[ -x "$H/.claude/statusline/statusline-command.sh" ] && [ -x "$H/.claude/statusline/cost-refresh.sh" ] && ! grep -q old "$H/.claude/statusline/cache/cost" 2>/dev/null'
# shellcheck disable=SC2088  # the point: a shell expands ~ in the configured command
OUT=$(HOME="$H" sh -c '~/.claude/statusline/statusline-command.sh </dev/null')
check "the configured command runs through a shell (~ expands)" eval '[ -n "$OUT" ]'
# own home: the first install's background refresh may still be writing to the other one
newhome; CUR="1 2 $NOW $(rolling) $((NOW + 3600)) 0.5"   # fresh, so the smoke-test render starts no refresh
echo "$CUR" >"$H/.claude/statusline/cache/cost"
HOME="$H" PATH="$S:$PATH" bash "$ROOT/install.sh" >/dev/null 2>&1; OUT=$(cat "$H/.claude/statusline/cache/cost")
check "re-install keeps a current-format cost cache" eval '[ "$OUT" = "$CUR" ]'
newhome
printf '{"statusLine": {"type": "command", "command": "~/old.sh", "padding": 2, "hideVimModeIndicator": true, "refreshInterval": 10}}\n' >"$H/.claude/settings.json"
HOME="$H" PATH="$S:$PATH" bash "$ROOT/install.sh" >/dev/null 2>&1; OUT=$(jq -cS .statusLine "$H/.claude/settings.json")
check "install keeps your statusLine keys (padding, hideVimModeIndicator, refreshInterval)" eval '[ "$OUT" = "{\"command\":\"~/.claude/statusline/statusline-command.sh\",\"hideVimModeIndicator\":true,\"padding\":2,\"refreshInterval\":10,\"type\":\"command\"}" ]'
HOME="$H" PATH="$S:$PATH" STATUSLINE_REFRESH=30 bash "$ROOT/install.sh" >/dev/null 2>&1; OUT=$(jq -c .statusLine.refreshInterval "$H/.claude/settings.json")
check "STATUSLINE_REFRESH overrides an existing refreshInterval" eval '[ "$OUT" = 30 ]'
newhome; printf 'not json{' >"$H/.claude/settings.json"
OUT=$(HOME="$H" PATH="$S:$PATH" STATUSLINE_REFRESH=0 bash "$ROOT/install.sh" 2>&1); RC=$?
check "malformed settings.json is backed up and replaced" eval '[ "$RC" -eq 0 ] && jq -e ".statusLine.command" "$H/.claude/settings.json" >/dev/null && grep -q "not json" "$H"/.claude/settings.json.bak.*'
check "STATUSLINE_REFRESH=0 leaves refreshInterval unset" eval '[ "$(jq ".statusLine | has(\"refreshInterval\")" "$H/.claude/settings.json")" = false ]'
OUT=$(HOME="$H" bash "$ROOT/uninstall.sh" 2>&1); RC=$?
check "uninstall removes our statusLine and the scripts" eval '[ "$RC" -eq 0 ] && [ "$(jq "has(\"statusLine\")" "$H/.claude/settings.json")" = false ] && [ ! -e "$H/.claude/statusline/statusline-command.sh" ]'
printf '{"statusLine": {"type": "command", "command": "~/other.sh"}}\n' >"$H/.claude/settings.json"
OUT=$(HOME="$H" bash "$ROOT/uninstall.sh" 2>&1)
check "uninstall leaves someone else's statusLine alone" eval '[ "$(jq -r .statusLine.command "$H/.claude/settings.json")" = "~/other.sh" ]'

# ---------------------------------------------------------------------------------------------------
echo
echo "$pass passed, $fail failed"
if [ "${1:-}" = --bash32 ]; then
  echo; echo "=== re-running under bash 3.2 (docker image bash:3.2) ==="
  docker run --rm -e LC_ALL=C.UTF-8 -v "$ROOT":/src:ro bash:3.2 sh -c \
    'apk add -q --no-progress jq git coreutils sed grep >/dev/null && bash /src/test/run.sh' || fail=$((fail + 1))
fi
[ "$fail" -eq 0 ]
