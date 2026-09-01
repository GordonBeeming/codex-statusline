#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
renderer="$repo_root/renderer/statusline.sh"
fixture="$repo_root/tests/fixtures/status-payload.json"

fixture_repo=$(mktemp -d)
trap 'rm -rf "$fixture_repo"' EXIT
git -C "$fixture_repo" init -q
git -C "$fixture_repo" branch -m gb/native-statusline
output=$(jq --arg cwd "$fixture_repo" '.cwd = $cwd' "$fixture" \
  | CODEX_STATUSLINE_AUD_PER_USD=1 "$renderer")
plain=$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')

line_count=$(printf '%s\n' "$plain" | awk 'END { print NR }')
[[ "$line_count" == "4" ]]
grep -Fq 'GPT-5.6 Sol' <<<"$plain"
grep -Fq 'high' <<<"$plain"
! grep -Fq 'API equiv' <<<"$plain"
grep -Fq '42% 5h' <<<"$plain"
grep -Fq '18% weekly' <<<"$plain"
grep -Fq '31% ctx' <<<"$plain"
! grep -Fq '325.5k / 1.1m' <<<"$plain"
grep -Fq '89.0k in / 14.0k out' <<<"$plain"

empty=$(printf '{}' | "$renderer")
[[ -z "$empty" ]]

marker="$fixture_repo/arithmetic-expansion-ran"
attack='x[$(touch '"$marker"')]'
jq --arg cwd "$fixture_repo" --arg attack "$attack" \
  '.cwd = $cwd
    | .context_window.total_input_tokens = $attack
    | .context_window.total_output_tokens = $attack' "$fixture" \
  | "$renderer" >/dev/null
[[ ! -e "$marker" ]]

printf 'renderer tests passed\n'
