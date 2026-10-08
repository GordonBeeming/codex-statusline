#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
renderer="$repo_root/renderer/statusline.sh"
fixture="$repo_root/tests/fixtures/status-payload.json"

fixture_root=$(mktemp -d)
fixture_repo="$fixture_root/main repo"
mkdir -p "$fixture_repo"
trap 'rm -rf "$fixture_root"' EXIT
git -C "$fixture_repo" init -q
git -C "$fixture_repo" branch -m gb/native-statusline
output=$(jq --arg cwd "$fixture_repo" '.cwd = $cwd' "$fixture" \
  | CODEX_STATUSLINE_AUD_PER_USD=1 "$renderer")
plain=$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')
[[ "${plain%%$'\n'*}" == '📂 main repo · '* ]]

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

assert_folder_label() {
  local cwd="$1" expected="$2" rendered
  rendered=$(jq --arg cwd "$cwd" '.cwd = $cwd' "$fixture" | "$renderer")
  [[ "${rendered%%$'\n'*}" == "📂 $expected · "* ]]
}

# Reuse a local commit so fixture setup needs no new commits or signing credentials.
git -C "$fixture_repo" fetch -q --update-shallow "$repo_root" HEAD
internal_worktree="$fixture_repo/.codex/worktrees/cool possum"
git -C "$fixture_repo" worktree add -q --detach "$internal_worktree" FETCH_HEAD
mkdir -p "$internal_worktree/nested/folder"
assert_folder_label "$internal_worktree" 'main repo/cool possum'
assert_folder_label "$internal_worktree/nested/folder" 'main repo/cool possum'

external_worktree="$fixture_root/external worktree"
git -C "$fixture_repo" worktree add -q -b gb/fix/external-fixture "$external_worktree" FETCH_HEAD
assert_folder_label "$external_worktree" 'main repo/external worktree'
mkdir -p "$fixture_repo/nested" "$fixture_root/plain folder"
assert_folder_label "$fixture_repo/nested" 'main repo'
assert_folder_label "$fixture_root/plain folder" 'plain folder'

printf 'renderer tests passed\n'
