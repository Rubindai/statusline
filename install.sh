#!/usr/bin/env bash
# Install the Claude Code status line.
#
#   * copies statusline-command.sh + cost-refresh.sh into ~/.claude/statusline/
#   * points "statusLine" in ~/.claude/settings.json at it, keeping your other statusLine keys
#     (padding, hideVimModeIndicator, ...) and every other setting
#     (backup first; a missing, empty or malformed file is backed up and replaced; atomic write)
#   * smoke-tests the installed renderer
#
# Works from a clone (uses the local scripts) or via curl | bash (downloads them). Re-runnable.
#   STATUSLINE_REFRESH=<seconds>  set statusLine.refreshInterval (0 removes it). Unset: keep yours, else 60
#   STATUSLINE_RAW_BASE=<url>     download source when not run from a clone
set -euo pipefail

REPO_RAW="${STATUSLINE_RAW_BASE:-https://raw.githubusercontent.com/Rubindai/statusline/main}"
SRC=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
DEST="$HOME/.claude/statusline"
SETTINGS="$HOME/.claude/settings.json"
# Claude Code runs the command through a shell, which expands ~ (also on Windows/Git Bash). That keeps
# settings.json portable across machines and safe when the home path contains spaces.
# shellcheck disable=SC2088
CMD='~/.claude/statusline/statusline-command.sh'
REFRESH="${STATUSLINE_REFRESH:-}"

say()  { printf '%s\n' "$*"; }
note() { printf 'note: %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

case $REFRESH in *[!0-9]*) die "STATUSLINE_REFRESH must be a whole number of seconds (got '$REFRESH')" ;; esac

# ---- dependencies --------------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "jq is required (https://jqlang.org). Install it and re-run."
command -v git >/dev/null 2>&1 || note "git not found: the branch segment stays hidden."
ccu=$(command -v ccusage 2>/dev/null || true)
[ -z "$ccu" ] && [ -x "$HOME/.local/bin/ccusage" ] && ccu="$HOME/.local/bin/ccusage"
if [ -n "$ccu" ]; then
  v=$("$ccu" --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1 || true)
  if [ -z "$v" ] || [ "${v%%.*}" -lt 20 ] 2>/dev/null; then
    note "ccusage ${v:-(unknown version)} at $ccu is too old; today/week cost needs ccusage >= 20."
    note "  upgrade it (npm install -g ccusage@latest, or a newer native binary; see the README)."
  fi
elif command -v npx >/dev/null 2>&1 || command -v bunx >/dev/null 2>&1; then
  note "ccusage is not installed, so each cost refresh fetches it through npx/bunx."
  note "  for faster, offline-friendly refreshes: npm install -g ccusage"
else
  note "ccusage not found: today/week cost stays hidden; everything else works."
  note "  without npm, install its native binary into ~/.local/bin (see 'Installing ccusage' in the README)."
fi

# The branch icon is a Powerline symbol (U+E0A0). Where fontconfig exists, check that some Powerline or
# Nerd font provides it (CJK fonts also use that private-use code point, for unrelated characters).
fonts=$(fc-list ':charset=e0a0' family 2>/dev/null || true)     # captured: no SIGPIPE under pipefail
if command -v fc-list >/dev/null 2>&1 && ! printf '%s\n' "$fonts" | grep -Eq '[Pp]owerline|Nerd Font| NF'; then
  note "no Powerline/Nerd font here, so the branch icon may show as a box. See 'Fonts' in the README,"
  note "  or use STATUSLINE_ASCII=1. (The font that counts is on the computer displaying the terminal.)"
fi

# ---- install the scripts (local clone first, else download) --------------------------------------
fetch() { # fetch <file>
  if [ -f "$SRC/$1" ]; then
    cp "$SRC/$1" "$DEST/$1.tmp"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW/$1" -o "$DEST/$1.tmp" || die "download failed: $REPO_RAW/$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$DEST/$1.tmp" "$REPO_RAW/$1" || die "download failed: $REPO_RAW/$1"
  else
    die "cannot obtain $1: no local copy, and neither curl nor wget is available."
  fi
  chmod +x "$DEST/$1.tmp" && mv -f "$DEST/$1.tmp" "$DEST/$1"
}
mkdir -p "$DEST/cache"
fetch statusline-command.sh
fetch cost-refresh.sh
# Drop state from earlier versions, whose cost cache (fewer than six fields) could include other
# agents' spend. A current cache is kept, so a re-install doesn't force a full re-read of the week.
cached6=''; [ -r "$DEST/cache/cost" ] && read -r _ _ _ _ _ cached6 _ <"$DEST/cache/cost" || true
[ -n "$cached6" ] || rm -f "$DEST/cache/cost"
rm -f "$DEST/cache/.cost.lock" "$DEST/cache/.cost.flock"
rm -rf "$DEST/cache/.cost.lock.d"

# ---- merge settings.json --------------------------------------------------------------------------
mkdir -p "$(dirname "$SETTINGS")"
stamp=$(date +%Y%m%d%H%M%S)
if [ -s "$SETTINGS" ] && jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.bak.$stamp"
  base=$(cat "$SETTINGS")
else
  if [ -s "$SETTINGS" ]; then cp "$SETTINGS" "$SETTINGS.bak.$stamp"; note "settings.json was not a JSON object; saved it as $SETTINGS.bak.$stamp"; fi
  base='{}'
fi
trap 'rm -f "$SETTINGS.tmp"' EXIT
printf '%s' "$base" | jq --arg cmd "$CMD" --arg r "$REFRESH" '
  .statusLine = ((.statusLine | if type == "object" then . else {} end)
    + {type: "command", command: $cmd}
    | .padding //= 0
    | if $r == "" then .refreshInterval //= 60
      elif ($r | tonumber) > 0 then .refreshInterval = ($r | tonumber)
      else del(.refreshInterval) end)' >"$SETTINGS.tmp"
mv -f "$SETTINGS.tmp" "$SETTINGS"

# ---- smoke test ---------------------------------------------------------------------------------
sample=$(jq -nc --arg d "$HOME" '{workspace: {current_dir: $d}, model: {display_name: "Opus"},
  context_window: {used_percentage: 25}, cost: {total_cost_usd: 0.42}}')
out=$(printf '%s' "$sample" | "$DEST/statusline-command.sh") && [ -n "$out" ] ||
  die "the installed renderer produced no output; run it with STATUSLINE_DEBUG=1 to see why."

say ""
say "Installed into $DEST"
say "settings.json statusLine: $(jq -c '.statusLine' "$SETTINGS")"
say ""
say "Preview with sample data:"
printf '%s\n' "$out" | sed 's/^/  /'
say ""
say "Claude Code picks up the change by itself; open sessions show it on their next update."
say "Blank? Accept the workspace-trust prompt, then see Troubleshooting in the README."
[ -e "$HOME/.claude/statusline-command.sh" ] &&
  note "an older copy at ~/.claude/statusline-command.sh is no longer used; you can delete it."
exit 0
