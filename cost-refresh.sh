#!/usr/bin/env bash
# Background cost refresh for the Claude Code status line.
#
# Runs `ccusage claude daily --json` and caches today's spend plus the spend since a window start, so
# the status line can show both without ever waiting on ccusage. statusline-command.sh starts it in
# its own session at the lowest CPU priority, at most once per TTL.
#
# Claude Code only: since ccusage v20 the bare `ccusage daily` also counts Codex, Gemini CLI,
# OpenCode, Amp and other agents' logs, so the `claude` subcommand is required here.
#
# Disk use: ccusage reads every transcript touched within its --since range, which for a busy week can
# be gigabytes. So the full window is read only once per day (and when the weekly cycle changes); the
# spend before today is kept in the cache, and the regular refreshes read only today's transcripts.
# Runs in the idle I/O class where `ionice` exists.
#
#   $1     window start, epoch seconds: seven_day.resets_at - 7d (the current weekly-limit cycle), or
#          a rolling 7-day start when no rate-limit data is available. Default: now - 7d.
#   cache  ~/.claude/statusline/cache/cost, one line:
#            <today_usd> <window_usd> <computed_at> <window_start> <next_local_midnight> <before_today_usd>
#          A usd field is "-" while unknown.
#
# Needs ccusage >= 20, installed with `npm install -g ccusage@latest` (or fetched on demand through
# bunx/npx). Exits 0 quietly on any failure, keeping still-valid figures.
set -u
DIR="$HOME/.claude/statusline/cache"
CACHE="$DIR/cost"
mkdir -p "$DIR" 2>/dev/null || exit 0
now=$(date +%s 2>/dev/null) || exit 0
win=${1:-}
case $win in ''|*[!0-9]*) win=$(( now - 604800 )) ;; esac
command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1   # idle I/O class, inherited by ccusage

# ---- single flight: flock where available (Linux), else an atomic mkdir lock (macOS) -------------
if command -v flock >/dev/null 2>&1; then
  exec 9>"$DIR/.lock" 2>/dev/null || exit 0
  flock -n 9 || exit 0
else
  LOCKD="$DIR/.lock.d"
  if ! mkdir "$LOCKD" 2>/dev/null; then
    pid=$(cat "$LOCKD/pid" 2>/dev/null)
    [ -z "$pid" ] && exit 0                                  # holder is still starting up
    kill -0 "$pid" 2>/dev/null && exit 0                     # holder is alive
    rm -rf "$LOCKD" 2>/dev/null; mkdir "$LOCKD" 2>/dev/null || exit 0   # reclaim a dead holder's lock
  fi
  echo $$ >"$LOCKD/pid" 2>/dev/null
  trap 'rm -rf "$LOCKD" 2>/dev/null' EXIT
  trap 'exit 0' HUP INT TERM
fi

# ---- dates (GNU date first; then BSD/macOS, where -r takes an epoch) -------------------------------
ymd() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null; }
day_end=$(date -d 'tomorrow 00:00' +%s 2>/dev/null || date -v+1d -v0H -v0M -v0S +%s 2>/dev/null)
case $day_end in ''|*[!0-9]*) day_end=$(( now + 3600 )) ;; esac
today=$(ymd "$now" %Y-%m-%d) || exit 0
win_day=$(ymd "$win" %Y-%m-%d) || exit 0

# ---- cache writes are atomic. Record the attempt first: renders then back off for a full TTL, -----
#      whether ccusage succeeds, fails or hangs. Carry over figures that are still valid.
put() { printf '%s %s %s %s %s %s\n' "$1" "$2" "$now" "$win" "$day_end" "$3" >"$DIR/.cost.$$" 2>/dev/null &&
        mv -f "$DIR/.cost.$$" "$CACHE" 2>/dev/null; }
keep_t=- keep_w=- past=-
if read -r t w _ ws de p _ <"$CACHE" 2>/dev/null; then
  same_win=0 same_day=0
  [ "$ws" = "$win" ] && same_win=1
  [ "${de:-0}" -gt "$now" ] 2>/dev/null && same_day=1          # cached before the coming midnight
  [ "$same_win" = 1 ] && keep_w=$w
  [ "$same_day" = 1 ] && keep_t=$t
  if [ "$same_win$same_day" = 11 ]; then case $p in ''|-|*[!0-9.eE+-]*) ;; *) past=$p ;; esac; fi
fi
put "$keep_t" "$keep_w" "$past"

# Spend before today is known: read only today's transcripts. Otherwise read the whole window, with a
# day of slack for timezone rounding, and remember the part before today.
if [ "$past" != - ]; then since=$(ymd "$now" %Y%m%d) || exit 0
else since=$(ymd "$(( win - 86400 ))" %Y%m%d) || exit 0; fi

# ---- find ccusage. Claude Code launched from a desktop/GUI gets a minimal PATH, so append where a
#      global npm install lands: npm prefixes, the newest fnm/nvm Node, other version managers, and
#      Homebrew (after the user's own PATH, which keeps precedence). ------------------------------------
shopt -s nullglob
newest() { [ $# -gt 0 ] && printf '%s\n' "$@" | { sort -V 2>/dev/null || sort; } | tail -n 1; }
for d in \
  "$HOME/.local/bin" "$HOME/bin" \
  "$(newest "${FNM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fnm}"/node-versions/*/installation/bin \
            "$HOME/Library/Application Support/fnm"/node-versions/*/installation/bin)" \
  "$(newest "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin)" \
  "${VOLTA_HOME:-$HOME/.volta}/bin" "${ASDF_DATA_DIR:-$HOME/.asdf}/shims" "${NODENV_ROOT:-$HOME/.nodenv}/shims" \
  "${PNPM_HOME:-$HOME/.local/share/pnpm}" "$HOME/.bun/bin" "$HOME/.npm-global/bin" \
  /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin
do
  [ -n "$d" ] && [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
done
export PATH                                     # an npm-installed ccusage needs node for its launcher

# Bound each run where `timeout` exists, so a hung npx can't hold the lock forever.
TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 120)
daily() { ${TO[@]+"${TO[@]}"} "$@" claude daily --json --since "$since" 2>/dev/null; }
json=''
command -v ccusage >/dev/null 2>&1 && json=$(daily ccusage)   # fails on a pre-v19 install
[ -z "$json" ] && command -v bunx >/dev/null 2>&1 && json=$(daily bunx ccusage@latest)
[ -z "$json" ] && command -v npx  >/dev/null 2>&1 && json=$(daily npx -y ccusage@latest)
[ -n "$json" ] || exit 0

# today = the bucket for today's local date; before = buckets from the window's start date up to
# yesterday (YYYY-MM-DD compares chronologically as a string), or the cached figure.
vals=$(jq -r --arg today "$today" --arg ws "$win_day" --arg past "$past" '
  if (.daily | type) != "array" then error("unexpected ccusage output") else . end
  | [.daily[] | {d: (.date // .period // ""), c: (.totalCost // 0)}] as $r
  | ([$r[] | select(.d == $today) | .c] | add // 0) as $t
  | (if $past == "-" then [$r[] | select(.d >= $ws and .d < $today) | .c] | add // 0
     else $past | tonumber end) as $p
  | "\($t) \($p + $t) \($p)"
' <<<"$json" 2>/dev/null) || exit 0
read -r t w p <<<"$vals"
case "$t$w$p" in ''|*[!0-9.eE+-]*) exit 0 ;; esac
put "$t" "$w" "$p"
exit 0
