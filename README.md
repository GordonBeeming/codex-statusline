# codex-statusline

A genuine command-backed, multiline status line for the native Codex CLI.

```text
📂 codex-statusline · 🤖 GPT-5.6 Sol · ⚡ high · Working · 2/5 tasks
🔀 gb/native-statusline
⏱️ ████░░░░░░ 42% 5h · 📅 █░░░░░░░░░ 18% weekly
💭 ███░░░░░░░ 31% ctx · 🧠 89.0k in / 14.0k out
```

This project mirrors the layout and extension model of
[`claude-statusline`](https://github.com/GordonBeeming/claude-statusline), but it renders inside
Codex's Ratatui interface rather than faking a footer through terminal output or tmux.

## Why a patched build?

Official Codex currently accepts only built-in identifiers in `tui.status_line`. It does not invoke
user commands, and its released footer deliberately stays on one line. The native patch in this
repository adds both missing capabilities:

- `[tui.status_line_command]` executes a user-level argv command asynchronously.
- Codex sends a versioned JSON session snapshot on stdin.
- Up to eight ANSI-SGR styled output lines can be rendered as fixed footer rows.
- Slow or failing commands keep the last successful output and never block drawing.
- Command output is capped and strips OSC, control, and bidirectional override sequences.
- Project-local `.codex/config.toml` files cannot register a status command.

The related upstream requests are
[`openai/codex#17827`](https://github.com/openai/codex/issues/17827) and
[`openai/codex#21653`](https://github.com/openai/codex/issues/21653). OpenAI's repository does not
accept external pull requests, so this project ships a reviewable patch against one pinned upstream
commit instead of maintaining a full source fork.

## Build and install

Requirements:

- macOS on Apple Silicon for the currently tested package
- Git, Rustup, Python 3.10+, DotSlash, and `jq`
- `jq` for the renderer
- Enough free disk space for a Codex release build

Run:

```bash
./install.sh
```

The builder:

1. Verifies the patch checksum and exact upstream commit in `upstream.lock`.
2. Clones that commit into a temporary directory.
3. Checks and applies `patches/native-statusline.patch`.
4. Uses Codex's canonical package builder, including the code-mode host and bundled resources.
5. Installs a versioned package under `~/.local/share/codex-statusline/releases/`.
6. Creates the separate `~/.local/bin/codex-statusline` launcher.

The official npm-managed `codex` command is left untouched as a rollback path.

The default is a release-profile build. For a faster, much larger local trial build, run
`CODEX_STATUSLINE_CARGO_PROFILE=dev ./install.sh`.

## Configure Codex

Add this user-level configuration to `~/.codex/config.toml`:

```toml
[tui]
status_line = []
terminal_title = ["spinner", "project"]

[tui.status_line_command]
command = ["/Users/YOU/.local/share/codex-statusline/current/renderer/statusline.sh"]
refresh_interval_ms = 1000
timeout_ms = 1000
max_lines = 4
```

Then launch:

```bash
codex-statusline
```

The patched binary deliberately ignores `tui.status_line_command` in repository configuration.
Only user, system, managed, or explicit runtime configuration may register an executable command.

## JSON contract

The renderer receives `schema_version: 1` with these groups:

- Thread identity, name, model, reasoning effort, and current run state
- Active working directory
- Canonical context used/remaining percentages and token totals
- Five-hour and weekly rate-limit windows when available
- Backend-provided thread cost/credits when the account exposes them
- Current task progress and terminal width

Unavailable fields are `null` or omitted by the corresponding nested value. Scripts should ignore
unknown fields so the payload can grow without breaking existing renderers.

## Cost semantics

Codex is included in ChatGPT plans, so token pricing is not a subscription invoice. The renderer
shows a session cost only when the backend provides a non-zero thread estimate. It does not derive
one from token counts because model switches, long-context rates, and cache semantics can make that
estimate misleading.

The renderer does not invent a daily monetary total. Codex currently provides rate-limit usage, not
a trustworthy daily ChatGPT subscription spend figure.

## Validate

Fast repository checks:

```bash
./scripts/verify.sh
```

The native patch has also been validated against the pinned Codex source with:

```bash
cd codex-rs
just fmt
cargo check -p codex-tui
just test -p codex-tui
```

The local full TUI run executed 4,113 tests. All new command-renderer and multiline-footer tests
passed. Remaining failures were pre-existing locale and terminal/editor-environment snapshots in
unchanged code paths.

## Updating upstream

Updates are intentionally manual:

1. Advance `UPSTREAM_COMMIT` and `UPSTREAM_VERSION` in `upstream.lock`.
2. Rebase the patch against that exact commit.
3. Regenerate `PATCH_SHA256`.
4. Run Codex formatting, schema generation, focused tests, and the full TUI suite.
5. Build into a new versioned release directory and switch `current` only after verification.

The previous official `codex` installation remains available even if a patched build fails.

## License and attribution

Licensed under Apache-2.0. OpenAI Codex's NOTICE and the credited source implementations are under
`THIRD_PARTY_NOTICES/`.
