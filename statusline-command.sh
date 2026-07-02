#!/usr/bin/env bash
# Claude Code status line — flat, |-separated, 3 lines.
#
# Design (approved): a flat statusline (NOT agnoster Powerline filled segments) styled
# after a reference screenshot: colored foreground text joined by dim `│` separators,
# restrained glyphs (a Powerline branch glyph + simple symbols ★ ● ⏳ ⚠ ↑ ↓ · − and ▰/▱ bar cells),
# a home-relative (~) path, and segmented-cell progress bars whose FILL color follows a
# colorblind-safe (Okabe-Ito) severity ramp. Layout:
#   line 1: ~path │ <branch> ↑a ●dirty │ ★ model  ● effort · <output-style>
#   line 2: Context <bar> N% │ 5H <bar> N% ⏳reset │ 7D <bar> N% ⏳reset · pace ±N%
#   line 3: $sess sess · $today today · $week week │ $burn/hr · work-time · +added −removed
# Any line/segment with no content is dropped entirely.
#
# Colors (truecolor, exact validated hexes; foreground only — no filled backgrounds):
#   severity  low #009E73 · med #E69F00 · high #D55E00 · critical #FF5FFF (magenta = near-full)
#   thresholds  <50 low · 50–79 med · 80–94 high (+!) · ≥95 critical (+⚠)
#   git clean #009E73 / dirty #E69F00 · path #56B4E9 · label #c3c2b7 · value #e6e6e6 · sep/empty #585858
# Identity of the three bars comes from the literal words Context/5H/7D (not from hue),
# and every bar always shows its N% — so meaning is never color-alone (WCAG / Okabe-Ito).
#
# DOES-NOT-BREAK-NATIVE-DISPLAY safeguards (auto/plan mode indicator, input box, spinner):
#   * emits ONLY SGR color escapes (\e[..m) — never cursor moves, clears, or other control seqs
#   * every colored span is reset, and a reset is force-appended to every emitted line
#   * NO_COLOR fully disables color; exits 0 always; writes nothing to stderr
#
# JSON fields read from stdin (per code.claude.com/docs/en/statusline):
#   .cwd/.workspace.current_dir · .model.display_name · .session_id · .output_style.name
#   .effort.level · .context_window.used_percentage · .cost.*
#   .rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}
# Graceful degradation: rate_limits are subscriber-only & absent until the first API
# response (→ 5H/7D/pace and the week-cost segment vanish); context % is null early (→ 0%).
#
# Today + week cost: computed by ccusage (the maintained Claude-Code cost tool — dedupes resumed
#   sessions, prices per-model across all ~/.claude/projects transcripts). cost-refresh.sh runs it in
#   the background (nice, ~5-min TTL), caching "<today> <week> <computed_at> <window_start>" to
#   ~/.claude/statusline/cache/cost so renders never block on node. "today" = ccusage's local-date
#   bucket; "week" = daily buckets summed since the weekly-limit cycle began (seven_day.resets_at − 7d).
#   $sess stays live from Claude Code's .cost.total_cost_usd. Backfilled + accurate across all history.
#
# Env switches: NO_COLOR=1 (no color) · STATUSLINE_ASCII=1 (ASCII glyphs, no Nerd Font).

input=$(cat)

COST_CACHE="$HOME/.claude/statusline/cache/cost"        # today+week cost (ccusage), refreshed in bg
COST_REFRESH="$HOME/.claude/statusline/cost-refresh.sh"
NOW=$(date +%s 2>/dev/null || echo 0)

# ---- colors (foreground-only truecolor; empty under NO_COLOR) --------------------------
if [ -z "${NO_COLOR:-}" ]; then
  e=$'\033'
  C_VAL="${e}[38;2;230;230;230m"
  C_LABEL="${e}[38;2;195;194;183m"
  C_SEP="${e}[38;2;88;88;88m"
  C_PATH="${e}[38;2;86;180;233m"
  C_STAR="${e}[38;2;245;197;66m"
  C_LOW="${e}[38;2;0;158;115m"
  C_MED="${e}[38;2;230;159;0m"
  C_HIGH="${e}[38;2;213;94;0m"
  C_CRIT="${e}[38;2;255;95;255m"
  C_EMPTY="${e}[38;2;88;88;88m"
  RST="${e}[0m"
else
  C_VAL=""; C_LABEL=""; C_SEP=""; C_PATH=""; C_STAR=""
  C_LOW=""; C_MED=""; C_HIGH=""; C_CRIT=""; C_EMPTY=""; RST=""
fi

# ---- glyphs (Nerd-Font/Unicode by default; ASCII fallback) -----------------------------
if [ -z "${STATUSLINE_ASCII:-}" ]; then
  G_FOLDER=''            # no path icon (clean text)
  G_BRANCH=$'\ue0a0 '   # powerline branch (U+E0A0) + trailing space
  G_FILL='▰'; G_EMPTY='▱'
  G_STAR='★'; G_DOT='●'
  G_RESET=$'\u23f3'; G_WARN=$'⚠︎'             # hourglass (U+23F3 emoji, time-until-reset) ; ⚠+VS15 (narrow)
  G_UP='↑'; G_DOWN='↓'
  G_SEP='│'; G_MID='·'; G_MINUS='−'
else
  G_FOLDER=''; G_BRANCH='git:'
  G_FILL='#'; G_EMPTY='-'
  G_STAR='*'; G_DOT='o'
  G_RESET='in '; G_WARN='!'
  G_UP='+'; G_DOWN='v'
  G_SEP='|'; G_MID='.'; G_MINUS='-'
fi
SEP=" ${C_SEP}${G_SEP}${RST} "          # between top-level segments
MID=" ${C_SEP}${G_MID}${RST} "          # between items within a segment

# ---- parse all fields in ONE jq call (perf: avoid ~15 jq spawns) -----------------------
cwd=""; model=""; ostyle=""; effort=""
ctx=""; cost="0"; dur_ms="0"; api_ms="0"; ladd="0"; lrem="0"
five_pct=""; five_rst=""; week_pct=""; week_rst=""
if command -v jq >/dev/null 2>&1; then
  eval "$(printf '%s' "$input" | jq -r '
    "cwd="      + ((.cwd // .workspace.current_dir // "")        | @sh),
    "model="    + ((.model.display_name // "")                   | @sh),
    "ostyle="   + ((.output_style.name // "")                    | @sh),
    "effort="   + ((.effort.level // "")                         | @sh),
    "ctx="      + ((.context_window.used_percentage // "" | tostring) | @sh),
    "cost="     + ((.cost.total_cost_usd // 0     | tostring)    | @sh),
    "dur_ms="   + ((.cost.total_duration_ms // 0  | tostring)    | @sh),
    "api_ms="   + ((.cost.total_api_duration_ms // 0 | tostring) | @sh),
    "ladd="     + ((.cost.total_lines_added // 0  | tostring)    | @sh),
    "lrem="     + ((.cost.total_lines_removed // 0 | tostring)   | @sh),
    "five_pct=" + ((.rate_limits.five_hour.used_percentage // "" | tostring) | @sh),
    "five_rst=" + ((.rate_limits.five_hour.resets_at // ""       | tostring) | @sh),
    "week_pct=" + ((.rate_limits.seven_day.used_percentage // "" | tostring) | @sh),
    "week_rst=" + ((.rate_limits.seven_day.resets_at // ""       | tostring) | @sh)
  ' 2>/dev/null)"
fi
[ -z "$cwd" ] && cwd=$(pwd 2>/dev/null)
[ -z "$cost" ] && cost="0"

# ---- helpers ---------------------------------------------------------------------------
# int part of a possibly-fractional percentage ("23.5" -> "23"; "" -> "0")
intpct() { local p="${1%.*}"; [ -z "$p" ] && p=0; printf '%s' "$p"; }

sev_color() { # $1 = integer pct -> severity color escape
  local p=$1
  if   [ "$p" -ge 95 ]; then printf '%s' "$C_CRIT"
  elif [ "$p" -ge 80 ]; then printf '%s' "$C_HIGH"
  elif [ "$p" -ge 50 ]; then printf '%s' "$C_MED"
  else                       printf '%s' "$C_LOW"; fi
}
sev_mark() { # $1 = integer pct -> " !" (high) / " ⚠" (critical) / ""
  local p=$1
  if   [ "$p" -ge 95 ]; then printf ' %s%s%s' "$C_CRIT" "$G_WARN" "$RST"
  elif [ "$p" -ge 80 ]; then printf ' %s!%s' "$C_HIGH" "$RST"; fi
}
make_bar() { # $1=int pct  $2=cells -> colored segmented bar (no % / no mark)
  local p=$1 n=$2 filled=0 i=0 out col
  filled=$(( (p * n + 50) / 100 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt "$n" ] && filled=$n
  col=$(sev_color "$p")
  out="$col"
  while [ "$i" -lt "$filled" ]; do out="${out}${G_FILL}"; i=$((i+1)); done
  out="${out}${C_EMPTY}"
  while [ "$i" -lt "$n" ]; do out="${out}${G_EMPTY}"; i=$((i+1)); done
  printf '%s%s' "$out" "$RST"
}
fmt_reset() { # $1 = resets_at epoch -> "2h16m" / "5d1h" / "now"
  local t=$1 d diff
  diff=$(( t - NOW ))
  [ "$diff" -le 0 ] && { printf 'now'; return; }
  d=$(( diff/86400 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$(( (diff%86400)/3600 ))"
  elif [ "$diff" -ge 3600 ]; then printf '%dh%dm' "$(( diff/3600 ))" "$(( (diff%3600)/60 ))"
  else printf '%dm' "$(( diff/60 ))"; fi
}
fmt_dur() { # $1 = ms -> "48m" / "1h48m" / "45s"
  local s=$(( ${1:-0}/1000 )) h m
  h=$(( s/3600 )); m=$(( (s%3600)/60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$(( s%60 ))"; fi
}
# pace = ideal% − used% ; ideal% = fraction of the 7d window already elapsed × 100
calc_pace() { # $1=seven_day.resets_at  $2=used_pct(float) -> signed int
  awk -v r="$1" -v u="$2" -v now="$NOW" 'BEGIN{
    rem = r - now; if (rem<0) rem=0; if (rem>604800) rem=604800;
    ideal = (1 - rem/604800) * 100; p = ideal - u;
    printf "%d", (p<0 ? p-0.5 : p+0.5);
  }'
}
# ---- today + week cost: read a ccusage-backed cache; refresh it in the background (never blocks) ----
# Cache line: "<today_usd> <week_usd> <computed_at_epoch> <window_start_epoch>"
today_cost=""; week_cost=""; c_at=0; c_ws=0
[ -r "$COST_CACHE" ] && read -r today_cost week_cost c_at c_ws < "$COST_CACHE" 2>/dev/null
# window = current weekly-limit cycle if known (ties $week to the 7D bar), else rolling 7 days
if [ -n "$week_rst" ]; then cost_win=$(( week_rst - 604800 )); else cost_win=$(( NOW - 604800 )); fi
# spawn a detached, low-priority refresh when the cache is missing/stale (>5m) or the window moved
if [ -x "$COST_REFRESH" ] && { [ ! -r "$COST_CACHE" ] || [ "$(( NOW - ${c_at:-0} ))" -gt 300 ] 2>/dev/null || [ "${c_ws:-0}" != "$cost_win" ]; }; then
  ( nice -n 19 "$COST_REFRESH" "$cost_win" >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

# ---- line 1: identity + model/mode -----------------------------------------------------
# home-relative path, middle-truncated when long
disp="$cwd"
case "$disp" in
  "$HOME")   disp="~" ;;
  "$HOME"/*) disp="~${disp#"$HOME"}" ;;
esac
if [ ${#disp} -gt 38 ] && [ "${disp%/*}" != "$disp" ]; then
  disp="${disp%%/*}/…/${disp##*/}"
fi
line1="${C_PATH}${G_FOLDER}${disp}${RST}"

# git segment (single work-tree probe; all calls guarded so a non-repo never errors)
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -c .)
    ab=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
    behind=$(printf '%s' "$ab" | cut -f1); ahead=$(printf '%s' "$ab" | cut -f2)
    gcol=$C_LOW; [ "${dirty:-0}" -gt 0 ] 2>/dev/null && gcol=$C_MED
    gseg="${gcol}${G_BRANCH}${branch}${RST}"
    [ -n "$ahead" ]  && [ "$ahead"  -gt 0 ] 2>/dev/null && gseg="$gseg ${C_LABEL}${G_UP}${ahead}${RST}"
    [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && gseg="$gseg ${C_LABEL}${G_DOWN}${behind}${RST}"
    [ "${dirty:-0}" -gt 0 ] 2>/dev/null && gseg="$gseg ${C_LABEL}${G_DOT}${dirty}${RST}"
    line1="$line1$SEP$gseg"
  fi
fi

# model + effort (adjacent) + think + output-style
if [ -n "$model" ]; then
  mseg="${C_STAR}${G_STAR}${RST} ${C_VAL}${model}${RST}"
  if [ -n "$effort" ]; then
    case "$effort" in
      low)    ecol=$C_SEP ;;  medium) ecol=$C_PATH ;;  high) ecol=$C_LOW ;;
      xhigh)  ecol=$C_MED ;;  max)    ecol=$C_CRIT ;;  *)    ecol=$C_LABEL ;;
    esac
    mseg="$mseg  ${ecol}${G_DOT}${RST} ${C_LABEL}${effort}${RST}"
  fi
  [ -n "$ostyle" ] && [ "$ostyle" != "default" ] && mseg="$mseg${MID}${C_LABEL}${ostyle}${RST}"
  line1="$line1$SEP$mseg"
fi

# ---- line 2: Context / 5H / 7D usage bars (one line) -----------------------------------
ci=$(intpct "$ctx")
line2="${C_LABEL}Context${RST} $(make_bar "$ci" 12) ${C_LABEL}${ci}%${RST}$(sev_mark "$ci")"

if [ -n "$five_pct" ]; then
  fi5=$(intpct "$five_pct")
  seg="${C_LABEL}5H${RST} $(make_bar "$fi5" 6) ${C_LABEL}${fi5}%${RST}$(sev_mark "$fi5")"
  [ -n "$five_rst" ] && seg="$seg ${C_LABEL}${G_RESET}$(fmt_reset "$five_rst")${RST}"
  line2="$line2$SEP$seg"
fi

if [ -n "$week_pct" ]; then
  wi=$(intpct "$week_pct")
  seg="${C_LABEL}7D${RST} $(make_bar "$wi" 6) ${C_LABEL}${wi}%${RST}$(sev_mark "$wi")"
  if [ -n "$week_rst" ]; then
    seg="$seg ${C_LABEL}${G_RESET}$(fmt_reset "$week_rst")${RST}"
    pace=$(calc_pace "$week_rst" "$week_pct")
    if [ "${pace:-0}" -ge 0 ] 2>/dev/null; then
      seg="$seg${MID}${C_LOW}pace +${pace}%${RST}"
    else
      seg="$seg${MID}${C_HIGH}pace ${G_MINUS}${pace#-}%${RST}"
    fi
  fi
  line2="$line2$SEP$seg"
fi

# ---- line 3: spend (session + week cost, burn, duration, lines) ------------------------
costf=$(printf '%.2f' "$cost" 2>/dev/null || printf '%s' "$cost")
line3="${C_VAL}\$${costf}${RST} ${C_LABEL}sess${RST}"
[ -n "$today_cost" ] && line3="$line3${MID}${C_VAL}\$$(printf '%.2f' "$today_cost" 2>/dev/null)${RST} ${C_LABEL}today${RST}"
[ -n "$week_cost" ]  && line3="$line3${MID}${C_VAL}\$$(printf '%.2f' "$week_cost" 2>/dev/null)${RST} ${C_LABEL}week${RST}"
if [ "${dur_ms:-0}" -gt 0 ] 2>/dev/null; then          # burn rate = spend per wall-clock hour
  burn=$(awk -v c="$cost" -v d="$dur_ms" 'BEGIN{h=d/3600000; printf "%.2f", (h>0? c/h : 0)}')
  line3="$line3$SEP${C_LABEL}\$${burn}/hr${RST}"
fi
if [ "${api_ms:-0}" -gt 0 ] 2>/dev/null; then          # API wait time (model compute; excludes local tool time)
  line3="$line3${MID}${C_LABEL}$(fmt_dur "$api_ms")${RST}"
fi
if [ "${ladd:-0}" -gt 0 ] 2>/dev/null || [ "${lrem:-0}" -gt 0 ] 2>/dev/null; then
  line3="$line3${MID}${C_LOW}+${ladd:-0}${RST} ${C_HIGH}${G_MINUS}${lrem:-0}${RST}"
fi

# ---- emit: drop empties, force a reset on every line (no color bleed into CC chrome) ----
out=()
[ -n "$line1" ] && out+=("${line1}${RST}")
[ -n "$line2" ] && out+=("${line2}${RST}")
[ -n "$line3" ] && out+=("${line3}${RST}")
printf '%s\n' "${out[@]}"
exit 0
