#!/usr/bin/env bash
# Installer for the Claude Code statusline.
#
#   • copies statusline-command.sh + cost-refresh.sh into ~/.claude/statusline/
#   • wires "statusLine" into ~/.claude/settings.json WITHOUT touching any other key
#     (backs the file up first; seeds {} if it's missing/empty/malformed; writes atomically)
#
# Works from a git clone (copies the local scripts) or via curl|bash (downloads them).
# Re-runnable / idempotent. Override the download source with STATUSLINE_RAW_BASE=<url>.
set -euo pipefail

REPO_RAW="${STATUSLINE_RAW_BASE:-https://raw.githubusercontent.com/Rubindai/statusline/main}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEST="$HOME/.claude/statusline"
SETTINGS="$HOME/.claude/settings.json"
CMD="$DEST/statusline-command.sh"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- dependencies -------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "jq is required (the statusline parses its JSON input with it). Install jq and re-run."
command -v git >/dev/null 2>&1 || say  "note: git not found — the branch segment will simply be hidden."
if ! command -v node >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1 && ! command -v bunx >/dev/null 2>&1; then
  say "note: node/npx/bunx not found — the today/week cost line needs ccusage (npm). Everything else works; that line stays blank."
fi

# ---- obtain the two scripts (local clone first, else download) ------------------------------
fetch() { # $1 = filename
  if [ -f "$SRC/$1" ]; then
    cp "$SRC/$1" "$DEST/$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW/$1" -o "$DEST/$1" || die "download failed: $REPO_RAW/$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$DEST/$1" "$REPO_RAW/$1" || die "download failed: $REPO_RAW/$1"
  else
    die "cannot obtain $1 — no local copy and neither curl nor wget is available."
  fi
  chmod +x "$DEST/$1"
}
mkdir -p "$DEST"
fetch statusline-command.sh
fetch cost-refresh.sh

# ---- merge settings.json (backup + atomic; never clobber siblings) --------------------------
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -s "$SETTINGS" ] || ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  [ -s "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)" || true   # keep even a malformed file
  base='{}'
else
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  base=$(cat "$SETTINGS")
fi
trap 'rm -f "$SETTINGS.tmp"' EXIT
printf '%s' "$base" | jq --arg cmd "$CMD" \
  '.statusLine = {type: "command", command: $cmd, padding: 0}' > "$SETTINGS.tmp"
mv -f "$SETTINGS.tmp" "$SETTINGS"

say ""
say "Installed:"
say "  $DEST/statusline-command.sh"
say "  $DEST/cost-refresh.sh"
say ""
say "settings.json → statusLine:"
jq '.statusLine' "$SETTINGS"
say ""
say "Done. Start a new Claude Code session (or run /statusline) to see it."
say "If it stays blank: accept the workspace-trust prompt, and check 'claude --debug' for the script's exit code."
