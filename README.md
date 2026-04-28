# codex-statusline

An enhanced status summary for Codex CLI that mirrors the four-line [`claude-statusline`](https://github.com/GordonBeeming/claude-statusline) layout as closely as Codex currently allows.

```text
📂 codex-statusline · 🔀 main
🤖 GPT-5.5 · ⚡ medium
💸 A$0.02 session · 💰 A$0.18 today · ⏱️ █░░░░░░░░░ 13% 4h10m left
💭 █░░░░░░░░░ 11% used · 89% left (29k / 258k)
```

## What It Shows

| Line | Purpose | Contents |
| --- | --- | --- |
| 1 | Identity | Repo/folder name and Git branch |
| 2 | Model | Current Codex model and reasoning effort |
| 3 | Spend and limits | Estimated session cost, estimated daily cost, 5-hour rate limit |
| 4 | Context | Current context window usage, matching the concept Codex shows in `/status` |

## Codex Limitation

Claude Code supports a command-backed status line. Codex CLI currently exposes `tui.status_line` as a list of built-in footer item identifiers, not as a command hook. See the [Codex config reference](https://developers.openai.com/codex/config-reference).

This repo therefore provides:

- `statusline.sh` — a Codex-native cost/status script that reads local Codex state and session JSONL logs
- `install.sh` — installs the script under `~/.codex/scripts/`, creates a `cs` shortcut, and prints the closest native Codex `tui.status_line` config

The script is useful as a terminal command, tmux status command, shell prompt segment, or a future Codex command-backed status provider if Codex adds that hook. Codex does not currently expose user-defined slash commands, so `/cs` is not available; use `cs` in the terminal instead.

## Install

```bash
./install.sh
```

Then run:

```bash
cs
```

`cs` is installed as a symlink in `~/.local/bin`. If that directory is not on your `PATH`, run the script directly:

```bash
~/.codex/scripts/codex-statusline.sh
```

For the closest built-in Codex footer, add this to `~/.codex/config.toml`:

```toml
[tui]
status_line = ["model-with-reasoning", "context-remaining", "current-dir", "git-branch"]
terminal_title = ["spinner", "project"]
```

## AUD Currency

All costs display in AUD by default. The exchange rate cache follows the same shape as [`goccc`](https://github.com/backstabslash/goccc):

```json
{
  "currency": "AUD",
  "cached_rate": 1.55,
  "rate_updated": "2026-04-28T13:30:00Z"
}
```

The default config path is:

```text
~/.codex-statusline.json
```

Rates are fetched from `https://open.er-api.com/v6/latest/USD` and cached for 24 hours. If the API is unavailable, the script uses the cached rate. If there is no cached rate yet, AUD falls back to `1.55` unless `CODEX_STATUSLINE_AUD_PER_USD` is set.

## Cost Model

Codex itself is included in ChatGPT plans, so this script shows an API-equivalent estimate rather than an invoice total. It uses [OpenAI's published API token rates](https://openai.com/api/pricing/) for:

- `gpt-5.5`
- `gpt-5.4`
- `gpt-5.4-mini`

Unknown models display with zero cost unless all three override variables are set:

```bash
export CODEX_STATUSLINE_PRICE_GPT_5_3_CODEX_INPUT=2.50
export CODEX_STATUSLINE_PRICE_GPT_5_3_CODEX_CACHED_INPUT=0.25
export CODEX_STATUSLINE_PRICE_GPT_5_3_CODEX_OUTPUT=15.00
```

Prices are USD per 1M tokens before conversion to AUD.

Cost estimates are calculated from cumulative billable input, cached input, and output tokens in Codex's local session log. The status line's context row is separate: it shows the current context window only, so it can be compared with `/status`.

## Dependencies

- `jq`
- `sqlite3`
- `git`
- `but` optional, for GitButler branch names
- `curl` optional, for exchange-rate refresh

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `CODEX_HOME` | `~/.codex` | Codex home directory |
| `CODEX_STATUSLINE_STATE_DB` | `$CODEX_HOME/state_5.sqlite` | Codex state database |
| `CODEX_STATUSLINE_SESSIONS_DIR` | `$CODEX_HOME/sessions` | Codex session JSONL directory |
| `CODEX_STATUSLINE_CURRENCY_CONFIG` | `~/.codex-statusline.json` | Currency config/cache file |
| `CODEX_STATUSLINE_CURRENCY` | `AUD` | Currency code used when config has no `currency` |
| `CODEX_STATUSLINE_AUD_PER_USD` | `1.55` | AUD fallback rate if no live or cached rate is available |
| `CODEX_STATUSLINE_CONTEXT_WINDOW` | `258400` | Fallback context window size |
