#!/usr/bin/env bash
# Uninstall the Claude Code status line.
#
#   * removes "statusLine" from ~/.claude/settings.json, but only when it points at this status line
#     (backup first; atomic write; every other key is left alone)
#   * deletes the installed scripts from ~/.claude/statusline/
#   * --purge also deletes ~/.claude/statusline/ entirely, including the cost cache
set -euo pipefail

DEST="$HOME/.claude/statusline"
SETTINGS="$HOME/.claude/settings.json"

if [ -s "$SETTINGS" ] && jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
  if jq -e '.statusLine.command? // "" | test("statusline/statusline-command\\.sh")' "$SETTINGS" >/dev/null 2>&1; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    trap 'rm -f "$SETTINGS.tmp"' EXIT
    jq 'del(.statusLine)' "$SETTINGS" >"$SETTINGS.tmp"
    mv -f "$SETTINGS.tmp" "$SETTINGS"
    printf '%s\n' "Removed statusLine from settings.json (backup saved)."
  else
    printf '%s\n' "settings.json's statusLine is not this status line; left it untouched."
  fi
else
  printf '%s\n' "No valid settings.json found; nothing to unwire."
fi

rm -f "$DEST/statusline-command.sh" "$DEST/cost-refresh.sh"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DEST"
  printf '%s\n' "Purged $DEST (including the cost cache)."
else
  printf '%s\n' "Removed the scripts. The cache is kept; re-run with --purge to delete $DEST entirely."
fi
