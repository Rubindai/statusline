#!/usr/bin/env bash
# Claude Code status line: three flat rows (where you are · headroom left · what it costs).
#
#   ~/dev/app │  main ↑2 ●5 │ ★ Opus 5.5  ● max · ↯ fast · Explanatory
#   Context ▰▰▰▰▱▱▱▱▱▱▱▱ 34% │ 5H ▰▰▱▱▱▱ 41% ⏳2h16m │ 7D ▰▰▰▰▱▱ 58% ⏳2d1h · pace +13%
#   $4.20 sess · $18.50 today · $92.00 week │ $6.30/hr · api 48m · +320 −140 │ cache 91% ⏳43m
#
# Input is the statusLine JSON on stdin: https://code.claude.com/docs/en/statusline
# (field list checked against the docs on 2026-11-01, Claude Code 2.1.316).
#
# Contract with Claude Code, which blanks the row on a non-zero exit or empty output:
#   * always exits 0 and always prints; stderr is discarded (STATUSLINE_DEBUG=1 keeps it)
#   * emits only SGR color escapes; every span is reset, and every row ends with a reset
#   * two child processes per render (jq, git); all number handling happens inside jq
#   * fits every row into $COLUMNS (set by Claude Code) by dropping the least important pieces
#   * today/week spend is read from a cache that cost-refresh.sh rebuilds in the background
#
# Segments appear only when their data exists: rate limits need a Pro/Max/Ultra plan (or a
# Claude apps gateway spend limit) and the session's first API response; prompt-cache stats need
# that response too; effort needs a model that supports it.
#
# Env: NO_COLOR=1 (no color) · STATUSLINE_ASCII=1 (plain ASCII glyphs, no Nerd Font needed).
# Portable to bash 3.2 (stock macOS): no \u escapes, namerefs, associative arrays or mapfile.

[ -n "${STATUSLINE_DEBUG:-}" ] || exec 2>/dev/null
IFS= read -r -d '' input              # all of stdin, without forking cat

STATE="$HOME/.claude/statusline"
COST_CACHE="$STATE/cache/cost"
COST_REFRESH="$STATE/cost-refresh.sh"
COST_TTL=300                          # seconds before today/week spend is recomputed

# ---- palette: Okabe-Ito severity ramp, foreground only ------------------------------------------
if [ -z "${NO_COLOR:-}" ]; then
  C_VAL=$'\e[38;2;230;230;230m'  C_LABEL=$'\e[38;2;195;194;183m'  C_DIM=$'\e[38;2;88;88;88m'
  C_PATH=$'\e[38;2;86;180;233m'  C_STAR=$'\e[38;2;245;197;66m'
  C_LOW=$'\e[38;2;0;158;115m'    C_MED=$'\e[38;2;230;159;0m'
  C_HIGH=$'\e[38;2;213;94;0m'    C_CRIT=$'\e[38;2;255;95;255m'
  RST=$'\e[0m'
else
  C_VAL='' C_LABEL='' C_DIM='' C_PATH='' C_STAR='' C_LOW='' C_MED='' C_HIGH='' C_CRIT='' RST=''
fi

# ---- glyphs --------------------------------------------------------------------------------------
if [ -z "${STATUSLINE_ASCII:-}" ]; then
  G_BRANCH=$'\xee\x82\xa0 '             # U+E0A0 Powerline branch (Nerd/Powerline font)
  G_TIME=$'\xe2\x8f\xb3'                # U+23F3 hourglass: "time until it resets / goes cold"
  G_WARN=$'\xe2\x9a\xa0\xef\xb8\x8e'    # U+26A0 + VS15 (text presentation, one cell)
  G_FILL='▰' G_EMPTY='▱' G_STAR='★' G_DOT='●' G_FAST='↯'
  G_UP='↑' G_DOWN='↓' G_BAR='│' G_MID='·' G_MINUS='−' G_ELL='…'
  G_WIDE=$G_TIME                        # the one glyph that occupies two terminal cells
else
  G_BRANCH='git:' G_TIME='in ' G_WARN='!!'
  G_FILL='#' G_EMPTY='-' G_STAR='*' G_DOT='o' G_FAST='>>'
  G_UP='^' G_DOWN='v' G_BAR='|' G_MID='.' G_MINUS='-' G_ELL='...'
  G_WIDE=''
fi
SEP=" ${C_DIM}${G_BAR}${RST} "        # between groups
MID=" ${C_DIM}${G_MID}${RST} "        # between items of one group

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "statusline: jq not found (https://jqlang.org)"
  exit 0
fi

# ---- parse: one jq call turns the JSON into shell assignments ------------------------------------
# Numbers are validated, floored and formatted here, so bash only ever sees integers or ''.
# shellcheck disable=SC2016  # jq program, not shell
JQ='
def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
def int: num | if . == null then "" else floor end;
def raw: num | if . == null then "" else . end;
def str: if . == null then "" else tostring end;
def span: if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m"
          elif . < 86400 then "\(. / 3600 | floor)h\(. % 3600 / 60 | floor)m"
          else "\(. / 86400 | floor)d\(. % 86400 / 3600 | floor)h" end;
def left($now): num | if . == null then "" else (. - $now | floor) | if . <= 0 then "now" else span end end;

(now | floor) as $now
| (.rate_limits // {}) as $rl
| (.cost // {}) as $c
| (.prompt_cache // {}) as $pc
| ($c.total_cost_usd | num // 0) as $cost
| ($c.total_duration_ms | num // 0) as $dur
| ($c.total_api_duration_ms | num // 0) as $api
| (.context_window.context_window_size | num) as $cws
| ($rl.seven_day.resets_at | num) as $wr
| ($rl.seven_day.used_percentage | num) as $wp
| @sh "NOW=\($now)",
  @sh "cwd=\(.workspace.current_dir // .cwd | str)",
  @sh "model=\(.model.display_name // .model.id | str)",
  @sh "effort=\(.effort.level | str)",
  @sh "fast=\(if .fast_mode == true then 1 else "" end)",
  @sh "ostyle=\(.output_style.name | str)",
  @sh "ctx=\(.context_window.used_percentage | int)",
  @sh "ctx_size=\(if $cws == null or $cws == 200000 then ""
                  elif $cws >= 1000000 then "\($cws / 1000000 | floor)M"
                  else "\($cws / 1000 | floor)k" end)",
  @sh "cost=\($cost)",
  @sh "burn=\(if $dur >= 60000 then $cost * 3600000 / $dur else "" end)",
  @sh "api=\(if $api >= 1000 then ($api / 1000 | floor | span) else "" end)",
  @sh "ladd=\($c.total_lines_added | int)",
  @sh "lrem=\($c.total_lines_removed | int)",
  @sh "five_pct=\($rl.five_hour.used_percentage | int)",
  @sh "five_left=\($rl.five_hour.resets_at | left($now))",
  @sh "week_pct=\($wp | int)",
  @sh "week_left=\($wr | left($now))",
  @sh "pace=\(if $wr == null or $wp == null then "" else
               ([$wr - $now, 0] | max) as $r | ([$r, 604800] | min) as $rem
               | (1 - $rem / 604800) * 100 - $wp
               | if . < 0 then 0 - (0.5 - . | floor) else (. + 0.5 | floor) end end)",
  @sh "win=\(if $wr != null then ($wr - 604800 | floor) else (($now - 604800) / 3600 | floor) * 3600 end)",
  @sh "spend_pct=\($rl.spend_limit.used_percentage | int)",
  @sh "spend_left=\($rl.spend_limit.resets_at | left($now))",
  @sh "spend_used=\($rl.spend_limit.used_usd | raw)",
  @sh "spend_cap=\($rl.spend_limit.limit_usd | raw)",
  @sh "pc_on=\(if $pc.caching_observed == true then 1 else "" end)",
  @sh "pc_warm=\(if $pc.warm == true then 1 else "" end)",
  @sh "pc_hit=\($pc.hit_ratio | num | if . == null then "" else (. * 100 | floor) end)",
  @sh "pc_left=\(if $pc.warm == true then ($pc.expires_at | left($now)) else "" end)"
'
NOW=0 cwd='' model='' effort='' fast='' ostyle='' ctx='' ctx_size='' cost=0 burn='' api=''
ladd=0 lrem=0 five_pct='' five_left='' week_pct='' week_left='' pace='' win=''
spend_pct='' spend_left='' spend_used='' spend_cap='' pc_on='' pc_warm='' pc_hit='' pc_left=''
eval "$(jq -r "$JQ" <<<"$input")"
[ "$NOW" -gt 0 ] || NOW=$(date +%s) || NOW=0
[ -n "$win" ] || win=$(( (NOW - 604800) / 3600 * 3600 ))
[ -n "$cwd" ] || cwd=$PWD

# ---- helpers (results go to REPLY / globals to avoid subshell forks) -----------------------------
usd() { # usd <number> -> REPLY: "4.20", or "186" from $100 up; returns 1 if not a number
  case $1 in ''|*[!0-9.eE+-]*) REPLY=''; return 1 ;; esac
  if [ "${1%%.*}" -ge 100 ] 2>/dev/null; then printf -v REPLY '%.0f' "$1"; else printf -v REPLY '%.2f' "$1"; fi
}
meter() { # meter <colored label> <int pct> <cells> -> REPLY: "label ▰▰▱▱ N%" + severity mark
  local p=$2 n=$3 f i bar='' col mark=''
  f=$(( (p * n + 50) / 100 )); [ "$f" -gt "$n" ] && f=$n
  if   [ "$p" -ge 95 ]; then col=$C_CRIT; mark=" ${C_CRIT}${G_WARN}${RST}"
  elif [ "$p" -ge 80 ]; then col=$C_HIGH; mark=" ${C_HIGH}!${RST}"
  elif [ "$p" -ge 50 ]; then col=$C_MED
  else                       col=$C_LOW; fi
  [ "$f" -gt 0 ] && bar=$col
  for ((i = 0; i < n; i++)); do
    [ "$i" -eq "$f" ] && bar+=$C_DIM
    if [ "$i" -lt "$f" ]; then bar+="$G_FILL"; else bar+="$G_EMPTY"; fi
  done
  REPLY="$1 ${bar}${RST} ${C_LABEL}${p}%${RST}${mark}"
}

# ---- row layout ----------------------------------------------------------------------------------
# A row is a list of segments. Segments sharing a group are joined by their own joiner (" ", "  " or
# " · "); groups are joined by " │ ". When the row is wider than the terminal, segments are dropped
# lowest priority first (priority 0 = never dropped), so the row degrades instead of wrapping.
BUDGET=0
case ${COLUMNS:-} in ''|*[!0-9]*) ;; *) [ "$COLUMNS" -gt 20 ] && BUDGET=$(( COLUMNS - 4 )) ;; esac
visible() { # visible <text> -> W, terminal cells: SGR escapes removed, the wide glyph counted twice
  local s=$1 out='' t           # linear scan; bash extglob replacement is quadratic on long rows
  while :; do
    case $s in *$'\e['*) ;; *) break ;; esac
    out+=${s%%$'\e['*}; s=${s#*$'\e['}; s=${s#*m}
  done
  out+=$s; W=${#out}
  if [ -n "$G_WIDE" ]; then t=${out//"$G_WIDE"/}; W=$(( W + ${#out} - ${#t} )); fi
}
visible "$SEP"; SEP_W=$W
GRP=() PRI=() JN=() TXT=() JW=() TW=()
seg() { # seg <group> <priority> <joiner> <text>; widths are measured once, here
  local n=${#TXT[@]}
  GRP[n]=$1 PRI[n]=$2 JN[n]=$3 TXT[n]=$4
  if [ "$BUDGET" -gt 0 ]; then visible "$3"; JW[n]=$W; visible "$4"; TW[n]=$W; fi
}
clear_row() { GRP=() PRI=() JN=() TXT=() JW=() TW=(); }
render() { # -> ROW
  local i prev=''
  ROW=''
  for ((i = 0; i < ${#TXT[@]}; i++)); do
    [ "${PRI[i]}" -lt 0 ] && continue
    if [ -z "$ROW" ]; then ROW=${TXT[i]}
    elif [ "${GRP[i]}" = "$prev" ]; then ROW+=${JN[i]}${TXT[i]}
    else ROW+=$SEP${TXT[i]}; fi
    prev=${GRP[i]}
  done
}
fits() { # does the row (minus dropped segments) fit in BUDGET?
  [ "$BUDGET" -eq 0 ] && return 0
  local i prev='' w=0 first=1
  for ((i = 0; i < ${#TXT[@]}; i++)); do
    [ "${PRI[i]}" -lt 0 ] && continue
    if [ "$first" = 1 ]; then first=0
    elif [ "${GRP[i]}" = "$prev" ]; then w=$(( w + JW[i] ))
    else w=$(( w + SEP_W )); fi
    w=$(( w + TW[i] )); prev=${GRP[i]}
  done
  [ "$w" -le "$BUDGET" ]
}
flush() { # fit the row, print it, start a new one
  local i lo li
  while ! fits; do
    li=-1 lo=999
    for ((i = 0; i < ${#TXT[@]}; i++)); do
      [ "${PRI[i]}" -gt 0 ] && [ "${PRI[i]}" -le "$lo" ] && { lo=${PRI[i]}; li=$i; }
    done
    [ "$li" -lt 0 ] && break                          # only pinned segments left
    PRI[li]=-1
  done
  render
  [ -n "$ROW" ] && printf '%s%s\n' "$ROW" "$RST"
  clear_row
}

# ---- row 1: path │ git │ model ---------------------------------------------------------------------
disp=$cwd
case $disp in "$HOME") disp='~' ;; "$HOME"/*) disp="~${disp#"$HOME"}" ;; esac
if [ "${#disp}" -gt 38 ] && [ "${disp%/*}" != "$disp" ]; then disp="${disp%%/*}/${G_ELL}/${disp##*/}"; fi
seg path 0 '' "${C_PATH}${disp}${RST}"

# one `git status` call yields branch, upstream ahead/behind and the dirty count
if command -v git >/dev/null 2>&1; then
  st=$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null)
  if [ -n "$st" ]; then
    head='' oid='' ahead=0 behind=0 dirty=0
    while IFS= read -r l; do
      case $l in
        '# branch.head '*) head=${l#'# branch.head '} ;;
        '# branch.oid '*)  oid=${l#'# branch.oid '} ;;
        '# branch.ab '*)   l=${l#'# branch.ab +'}; ahead=${l%% *}; behind=${l##*-} ;;
        '#'*) ;;
        ?*) dirty=$(( dirty + 1 )) ;;
      esac
    done <<<"$st"
    [ "$head" = '(detached)' ] && head=${oid:0:7}
    [ "${#head}" -gt 32 ] && head="${head:0:31}${G_ELL}"
    case $ahead  in ''|*[!0-9]*) ahead=0 ;;  esac
    case $behind in ''|*[!0-9]*) behind=0 ;; esac
    gcol=$C_LOW; [ "$dirty" -gt 0 ] && gcol=$C_MED
    seg git 6 '' "${gcol}${G_BRANCH}${head}${RST}"
    [ "$ahead"  -gt 0 ] && seg git 3 ' ' "${C_LABEL}${G_UP}${ahead}${RST}"
    [ "$behind" -gt 0 ] && seg git 3 ' ' "${C_LABEL}${G_DOWN}${behind}${RST}"
    [ "$dirty"  -gt 0 ] && seg git 3 ' ' "${C_LABEL}${G_DOT}${dirty}${RST}"
  fi
fi

if [ -n "$model" ]; then
  seg model 7 '' "${C_STAR}${G_STAR}${RST} ${C_VAL}${model}${RST}"
  if [ -n "$effort" ]; then
    case $effort in
      low) ec=$C_DIM ;; medium) ec=$C_PATH ;; high) ec=$C_LOW ;; xhigh) ec=$C_MED ;; max) ec=$C_CRIT ;; *) ec=$C_LABEL ;;
    esac
    seg model 5 '  ' "${ec}${G_DOT}${RST} ${C_LABEL}${effort}${RST}"
  fi
  [ -n "$fast" ] && seg model 4 "$MID" "${C_MED}${G_FAST} fast${RST}"
  case $ostyle in ''|default|Default) ;; *) seg model 1 "$MID" "${C_LABEL}${ostyle}${RST}" ;; esac
fi
flush

# ---- row 2: context and plan limits -----------------------------------------------------------------
row2() { # row2 <context cells> <limit cells>
  local label="${C_LABEL}Context${RST}"
  [ -n "$ctx_size" ] && label+=" ${C_DIM}${ctx_size}${RST}"
  meter "$label" "${ctx:-0}" "$1"; seg ctx 0 '' "$REPLY"
  if [ -n "$five_pct" ]; then
    meter "${C_LABEL}5H${RST}" "$five_pct" "$2"; seg 5h 8 '' "$REPLY"
    [ -n "$five_left" ] && seg 5h 4 ' ' "${C_LABEL}${G_TIME}${five_left}${RST}"
  fi
  if [ -n "$week_pct" ]; then
    meter "${C_LABEL}7D${RST}" "$week_pct" "$2"; seg 7d 7 '' "$REPLY"
    [ -n "$week_left" ] && seg 7d 3 ' ' "${C_LABEL}${G_TIME}${week_left}${RST}"
    if [ -n "$pace" ]; then
      if [ "$pace" -ge 0 ]; then seg 7d 2 "$MID" "${C_LOW}pace +${pace}%${RST}"
      else                       seg 7d 2 "$MID" "${C_HIGH}pace ${G_MINUS}${pace#-}%${RST}"; fi
    fi
  fi
  if [ -n "$spend_pct" ]; then                       # Claude apps gateway spend limit
    meter "${C_LABEL}Spend${RST}" "$spend_pct" "$2"; seg spend 6 '' "$REPLY"
    [ -n "$spend_left" ] && seg spend 3 ' ' "${C_LABEL}${G_TIME}${spend_left}${RST}"
    if usd "$spend_used"; then
      local used=$REPLY
      usd "$spend_cap" && seg spend 5 "$MID" "${C_VAL}\$${used}${RST}${C_LABEL}/\$${REPLY}${RST}"
    fi
  fi
}
row2 12 6
fits || { clear_row; row2 6 4; }                     # narrow terminal: shorter bars first
flush

# ---- row 3: spend ------------------------------------------------------------------------------------
# today/week come from the background ccusage cache: "<today> <week> <computed_at> <window> <day_end> ..."
today_cost='' week_cost='' c_at=0 c_win=0 c_end=0
[ -r "$COST_CACHE" ] && read -r today_cost week_cost c_at c_win c_end _ <"$COST_CACHE"
case $c_at  in ''|*[!0-9]*) c_at=0 ;;  esac
case $c_win in ''|*[!0-9]*) c_win=0 ;; esac
case $c_end in ''|*[!0-9]*) c_end=0 ;; esac
[ "$c_win" = "$win" ] || week_cost=''               # cached for a different weekly cycle
[ "$NOW" -lt "$c_end" ] || today_cost=''            # cached before local midnight
if [ -x "$COST_REFRESH" ] && { [ $(( NOW - c_at )) -gt "$COST_TTL" ] || [ "$c_win" != "$win" ] || [ "$NOW" -ge "$c_end" ]; }; then
  # Claude Code cancels a render that is still running when the next one starts, so the refresh gets
  # its own session (setsid; perl's on macOS) and outlives this process group. Lowest CPU priority;
  # on macOS also the background I/O policy (the refresh sets the idle I/O class itself on Linux).
  run=(nice -n 19 "$COST_REFRESH" "$win")
  command -v taskpolicy >/dev/null 2>&1 && run=(taskpolicy -b "${run[@]}")
  if command -v setsid >/dev/null 2>&1; then run=(setsid "${run[@]}")
  elif command -v perl >/dev/null 2>&1; then run=(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 1' "${run[@]}"); fi
  ( "${run[@]}" </dev/null >/dev/null 2>&1 & )
fi

usd "$cost" || REPLY='0.00'
seg spend 0 '' "${C_VAL}\$${REPLY}${RST} ${C_LABEL}sess${RST}"
usd "$today_cost" && seg spend 7 "$MID" "${C_VAL}\$${REPLY}${RST} ${C_LABEL}today${RST}"
usd "$week_cost"  && seg spend 6 "$MID" "${C_VAL}\$${REPLY}${RST} ${C_LABEL}week${RST}"
usd "$burn"       && seg rate 3 '' "${C_LABEL}\$${REPLY}/hr${RST}"
[ -n "$api" ]     && seg rate 2 "$MID" "${C_LABEL}api ${api}${RST}"
if [ "${ladd:-0}" -gt 0 ] || [ "${lrem:-0}" -gt 0 ]; then
  seg rate 4 "$MID" "${C_LOW}+${ladd:-0}${RST} ${C_HIGH}${G_MINUS}${lrem:-0}${RST}"
fi
if [ -n "$pc_on" ]; then                            # prompt cache: warm (with time left) or cold
  if [ -n "$pc_warm" ]; then
    t="${C_LOW}cache${pc_hit:+ ${pc_hit}%}${RST}"
    [ -n "$pc_left" ] && t+=" ${C_LABEL}${G_TIME}${pc_left}${RST}"
  else
    t="${C_MED}cache${pc_hit:+ ${pc_hit}%} cold${RST}"
  fi
  seg cache 5 '' "$t"
fi
flush
exit 0
