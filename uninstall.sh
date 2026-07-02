#!/usr/bin/env bash
# Uninstaller for the Claude Code statusline.
#
#   • removes the "statusLine" key from ~/.claude/settings.json (backup + atomic; leaves siblings intact)
#   • removes the installed scripts from ~/.claude/statusline/
#   • pass --purge to also delete ~/.claude/statusline/ entirely (including the cost cache)
set -euo pipefail

DEST="$HOME/.claude/statusline"
SETTINGS="$HOME/.claude/settings.json"

if [ -s "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  trap 'rm -f "$SETTINGS.tmp"' EXIT
  jq 'del(.statusLine)' "$SETTINGS" > "$SETTINGS.tmp"
  mv -f "$SETTINGS.tmp" "$SETTINGS"
  printf '%s\n' "Removed .statusLine from settings.json (backup saved)."
else
  printf '%s\n' "No valid settings.json found — nothing to unwire."
fi

rm -f "$DEST/statusline-command.sh" "$DEST/cost-refresh.sh"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DEST"
  printf '%s\n' "Purged $DEST (including the cost cache)."
else
  printf '%s\n' "Removed installed scripts. Cache kept — re-run with --purge to delete $DEST entirely."
fi
