# Claude Code statusline

A flat, three-line [status line](https://code.claude.com/docs/en/statusline) for Claude Code: context &
rate-limit usage bars, session / today / week spend, and git state — in a colorblind-safe palette, with no
blocking work on the render path.

![statusline demo](screenshots/demo.svg)

*(Sample values. Colors follow the [Okabe–Ito](https://jfly.uni-koeln.de/color/) colorblind-safe palette; the
bar fill and severity bands are computed exactly as the script renders them.)*

---

## What the three lines show

**Line 1 — identity**
`~/dev/statusline │ ⎇ main ↑2 ●5 │ ★ Opus 4.8  ● max`
- home-relative path (middle-truncated when long)
- git branch, colored green when clean / amber when dirty, with `↑`ahead `↓`behind `●`dirty counts
- `★` model name, then a `●` effort dot + level (`low … max`), then the output style if non-default

**Line 2 — usage** (each bar is 12 cells for context, 6 for the limits; the fill color follows a severity ramp)
`Context ▰▰▰▰▱▱▱▱▱▱▱▱ 34% │ 5H ▰▰▱▱▱▱ 41% ⏳2h16m │ 7D ▰▰▰▰▱▱ 58% ⏳2d1h · pace +13%`
- **Context** — percent of the context window used (input tokens only, per the docs)
- **5H / 7D** — your Claude.ai Pro/Max rate-limit windows, each with a `⏳` countdown to reset
- **pace** — how your 7-day burn compares to a straight line (see [Pace](#pace) below)

**Line 3 — spend**
`$4.20 sess · $18.50 today · $92.00 week │ $6.30/hr · 1h48m · +320 −140`
- **sess / today / week** cost, **$/hr** burn rate, API compute time, and lines added/removed

Any line or segment with no data is dropped entirely — non-subscribers simply won't see the 5H/7D/pace/week
pieces.

## Requirements

| | |
|---|---|
| **Required** | `bash` (4+), [`jq`](https://jqlang.github.io/jq/) |
| **Optional** | `git` (branch segment) · Node + [`ccusage`](https://ccusage.com) (today/week cost) · a Powerline/Nerd font for the `⎇` branch glyph (else use `STATUSLINE_ASCII=1`) |
| **Platforms** | Linux, macOS, and Windows via Git Bash / WSL |

Nothing optional is fatal: miss `git` and the branch hides; miss `ccusage`/Node and only the today/week
figures stay blank. The script always exits `0`, so the status line never goes blank on an error.

## Install

**One-liner** (reads then runs the installer):
```sh
curl -fsSL https://raw.githubusercontent.com/Rubindai/statusline/main/install.sh | bash
```

**Clone** (inspect first, recommended):
```sh
git clone https://github.com/Rubindai/statusline.git
cd statusline
./install.sh
```

**Manual:** copy `statusline-command.sh` and `cost-refresh.sh` into `~/.claude/statusline/`, `chmod +x` both,
then add this to `~/.claude/settings.json` (use your real absolute path — `settings.json` does not expand `~`):
```json
{
  "statusLine": {
    "type": "command",
    "command": "/home/you/.claude/statusline/statusline-command.sh",
    "padding": 0
  }
}
```

The installer merges only the `statusLine` key — every other setting is preserved, and your existing
`settings.json` is backed up first. Start a new session (or `/statusline`) and accept the workspace-trust
prompt to see it.

> Replace `Rubindai/statusline` in the URLs above if you host this under a different repo.

## How the cost line works

- **`sess`** is live, straight from Claude Code's own `cost.total_cost_usd` (its client-side estimate).
- **`today` / `week`** are computed by [`ccusage`](https://ccusage.com), which reads your local
  `~/.claude/projects` transcripts, de-duplicates resumed/branched sessions, and prices each model.
  - `today` = ccusage's daily bucket for the local date.
  - `week` = daily buckets summed since the current weekly-limit cycle began (`seven_day.resets_at − 7 days`),
    so it lines up with the **7D** bar. It falls back to a rolling 7-day window when rate-limit data isn't
    available yet.
- To keep rendering instant, `cost-refresh.sh` runs `ccusage` **in the background** (niced, single-flight,
  ~5-minute cache) and writes `today week computed_at window_start` to `~/.claude/statusline/cache/cost`. The
  status line only ever reads that cache — it never waits on Node.

**Honest caveats:** these figures are **local to this machine** (transcripts on other computers and work on
claude.ai aren't counted) and are an **API-equivalent estimate at list prices**, not your Pro/Max
subscription bill. Because ccusage buckets by calendar day, the week window rounds to the cycle-start's date.

## Pace

`pace = ideal% − used%`, where `ideal%` is the fraction of the 7-day window already elapsed. So:

- **`pace +N%`** (green) — you've used *N points less* than a straight-line burn predicts → comfortably under budget.
- **`pace −N%`** (red) — you're *N points over* the straight line → at this rate you'll hit the weekly limit early.

It's a purely local, informational read derived from the account-wide `seven_day` numbers Claude Code hands the
script — no network calls.

## Customization

All knobs live at the top of `statusline-command.sh`:

- **No color:** run under `NO_COLOR=1` — set it in the command, e.g.
  `"command": "NO_COLOR=1 /home/you/.claude/statusline/statusline-command.sh"`.
- **No special glyphs** (boxes/tofu instead of icons): `STATUSLINE_ASCII=1` the same way — falls back to plain
  ASCII (`git:`, `#`/`-` bar cells, `*`/`o`, …).
- **Colors & thresholds:** edit the `C_*` hexes and the `sev_color` cut-offs (`50 / 80 / 95`).
- **Bar width:** the second argument to `make_bar` (12 for context, 6 for the limits).
- **Spacing:** `statusLine.padding` in `settings.json`.
- **Live idle countdown:** by default the line refreshes on each new message and after `/compact`; Claude
  Code's `statusLine.refreshInterval` setting can re-run it on a timer so the 5H/7D countdown keeps ticking
  while you're idle — see the [official statusLine docs](https://code.claude.com/docs/en/statusline) for the
  value and version support.

## Troubleshooting

- **Status line is blank** — the script must be executable (`chmod +x`) and you must have accepted the
  workspace-trust prompt. Run `claude --debug` to see the script's exit code and stderr from its first run.
  Claude Code blanks the line if a script exits non-zero or prints nothing.
- **`today`/`week` cost never appear** — `ccusage`/Node isn't discoverable, or the first refresh hasn't
  finished. Test it directly: `~/.claude/statusline/cost-refresh.sh $(date +%s)` then inspect
  `~/.claude/statusline/cache/cost`. Make sure `npx -y ccusage --version` works.
- **Icons render as boxes** — your font lacks Powerline/Nerd glyphs; use `STATUSLINE_ASCII=1` (above).

## Uninstall

```sh
./uninstall.sh            # removes the statusLine key (backup kept) + the installed scripts
./uninstall.sh --purge    # also deletes ~/.claude/statusline/ (including the cost cache)
```

## Credits

Today/week cost is powered by [**ccusage**](https://github.com/ryoppippi/ccusage) by ryoppippi. Colors use the
Okabe–Ito colorblind-safe palette.

## License

[MIT](LICENSE)
