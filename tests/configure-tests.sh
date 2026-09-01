#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT

mkdir -p "$test_home/.codex"
printf '[tui]\nstatus_line = ["model"]\n' > "$test_home/.codex/config.toml"

HOME="$test_home" python3 "$repo_root/scripts/configure.py"
HOME="$test_home" python3 "$repo_root/scripts/configure.py"

config="$test_home/.codex/config.toml"
[[ $(grep -c '^\[tui.status_line_command\]$' "$config") == 1 ]]
grep -Fq 'status_line = ["model"]' "$config"
grep -Fq "$test_home/.local/share/codex-statusline/current/renderer/statusline.sh" "$config"

printf 'configure tests passed\n'
