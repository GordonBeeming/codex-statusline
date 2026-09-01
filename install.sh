#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$repo_root/scripts/build-native.sh"
python3 "$repo_root/scripts/configure.py"

printf '\nNative Codex status line installed.\n'
printf 'Launch it with: codex-statusline\n'
printf 'The official codex command remains unchanged.\n'
