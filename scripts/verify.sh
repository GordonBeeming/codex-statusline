#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../upstream.lock
source "$repo_root/upstream.lock"

"$repo_root/tests/renderer-tests.sh"
"$repo_root/tests/configure-tests.sh"

actual_patch_sha=$(shasum -a 256 "$repo_root/patches/native-statusline.patch" | awk '{print $1}')
[[ "$actual_patch_sha" == "$PATCH_SHA256" ]]

if [[ -x "${HOME}/.local/bin/codex-statusline" ]]; then
  "${HOME}/.local/bin/codex-statusline" --version
fi

printf 'verification passed\n'
