#!/usr/bin/env bash
# Background cost refresh for the Claude Code statusline (cross-platform: Linux + macOS).
#
# Queries ccusage (the maintained Claude-Code cost tool — it reads ~/.claude/projects transcripts,
# dedupes resumed/branched sessions, and prices per-model) and writes today + window cost to a cache
# the statusline reads instantly. Runs OFF the render path (spawned detached), so renders never block
# on node startup.
#
# Arg $1 = window-start epoch (start of the current cost window). The statusline passes the current
#          weekly-limit cycle start (seven_day.resets_at − 7d) when available, else a rolling-7-day start.
#          Defaults to now−7d.
# Cache   ~/.claude/statusline/cache/cost  ->  "<today_usd> <window_usd> <computed_at_epoch> <window_start_epoch>"
#
# Portability:
#   * epoch→date via epoch_to_date() — GNU `date -d @N` first, BSD/macOS `date -r N` fallback.
#   * ccusage located via find_ccusage() across fnm/nvm/volta/asdf/nodenv/Homebrew/system, then
#     `bunx`/`npx -y` — because a GUI-launched Claude Code inherits only a minimal login PATH.
#   * single-flight via flock when present, else an atomic mkdir lock (works on stock macOS).
#
# Exits 0 quietly on ANY problem (no ccusage, no node, jq error, …), leaving the previous cache in place
# so the statusline degrades gracefully.
set -u
DIR="$HOME/.claude/statusline/cache"
mkdir -p "$DIR" 2>/dev/null || exit 0
now=$(date +%s 2>/dev/null || echo 0)
win=${1:-$(( now - 604800 ))}

# ---- single-flight lock: flock (auto-releases on death) when available, else atomic mkdir ----------
LOCKD="$DIR/.cost.lock.d"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$DIR/.cost.flock" 2>/dev/null || exit 0
  flock -n 9 || exit 0
else
  # mkdir is atomic on POSIX filesystems: exactly one caller wins the race.
  if mkdir "$LOCKD" 2>/dev/null; then
    echo $$ > "$LOCKD/pid" 2>/dev/null
    trap 'rm -rf "$LOCKD" 2>/dev/null' EXIT INT TERM
  else
    # Stale-lock reclaim: if the recorded holder is dead, take over once.
    pid=$(cat "$LOCKD/pid" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$LOCKD" 2>/dev/null
      mkdir "$LOCKD" 2>/dev/null || exit 0
      echo $$ > "$LOCKD/pid" 2>/dev/null
      trap 'rm -rf "$LOCKD" 2>/dev/null' EXIT INT TERM
    else
      exit 0                                   # another refresh is live
    fi
  fi
fi

# ---- portable epoch -> formatted date (GNU date -d first; -d before -r since GNU -r = file mtime) ----
epoch_to_date() { date -d "@$1" "${2:-+%Y-%m-%d}" 2>/dev/null || date -r "$1" "${2:-+%Y-%m-%d}" 2>/dev/null; }

# ---- locate a ccusage invocation across node version managers / minimal GUI PATH -------------------
# Populates the array CCUSAGE_CMD (may be multi-word, e.g. "npx -y ccusage", or a full path with spaces).
newest_dir() { printf '%s\n' "$@" | sort -V | tail -n1; }   # newest existing match by version sort
CCUSAGE_CMD=()
find_ccusage() {
  command -v ccusage >/dev/null 2>&1 && { CCUSAGE_CMD=(ccusage); return 0; }
  shopt -s nullglob 2>/dev/null                              # unmatched globs vanish instead of staying literal
  local c fnm_bin nvm_bin
  fnm_bin=$(newest_dir \
    "${FNM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fnm}"/node-versions/*/installation/bin \
    "$HOME/Library/Application Support/fnm"/node-versions/*/installation/bin)
  nvm_bin=$(newest_dir "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin)
  local dirs=(
    "${VOLTA_HOME:-$HOME/.volta}/bin"
    /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin
    "$fnm_bin" "$nvm_bin"
    "${ASDF_DATA_DIR:-$HOME/.asdf}/shims"
    "${NODENV_ROOT:-$HOME/.nodenv}/shims"
    /usr/bin
  )
  for c in "${dirs[@]}"; do
    [ -n "$c" ] || continue
    [ -x "$c/ccusage" ] && { CCUSAGE_CMD=("$c/ccusage"); return 0; }
    [ -x "$c/node" ] && PATH="$c:$PATH"                      # make node visible for the npx/bunx fallback
  done
  export PATH
  command -v ccusage >/dev/null 2>&1 && { CCUSAGE_CMD=(ccusage);        return 0; }
  command -v bunx    >/dev/null 2>&1 && { CCUSAGE_CMD=(bunx ccusage);   return 0; }   # ephemeral runners
  command -v npx     >/dev/null 2>&1 && { CCUSAGE_CMD=(npx -y ccusage); return 0; }
  return 1
}
find_ccusage || exit 0

win_date=$(epoch_to_date "$win" +%Y-%m-%d) || exit 0
since=$(epoch_to_date "$(( win - 86400 ))" +%Y%m%d) || exit 0   # 1 day of slack for tz/rounding
today=$(date +%Y-%m-%d 2>/dev/null) || exit 0

json=$("${CCUSAGE_CMD[@]}" daily --json --since "$since" 2>/dev/null) || exit 0
[ -n "$json" ] || exit 0

# today = the daily bucket matching today's date; window = sum of daily buckets on/after win_date.
# (.period is "YYYY-MM-DD"; lexical >= is chronological >=.)
vals=$(printf '%s' "$json" | jq -r --arg today "$today" --arg ws "$win_date" '
  { t: ((.daily[] | select(.period == $today) | .totalCost) // 0),
    w: ([ .daily[] | select(.period >= $ws) | .totalCost ] | add // 0) }
  | "\(.t) \(.w)"' 2>/dev/null) || exit 0
[ -n "$vals" ] || exit 0
# shellcheck disable=SC2086
set -- $vals
t=${1:-0}; w=${2:-0}

tmp="$DIR/.cost.$$.tmp"
printf '%s %s %s %s\n' "$t" "$w" "$now" "$win" > "$tmp" 2>/dev/null && mv -f "$tmp" "$DIR/cost" 2>/dev/null
exit 0
