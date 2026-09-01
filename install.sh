#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$repo_root/scripts/build-native.sh"
share_root=${CODEX_STATUSLINE_SHARE_ROOT:-"${HOME}/.local/share/codex-statusline"}
python_bin=${CODEX_STATUSLINE_PYTHON:-}
if [[ -z "$python_bin" && -x /opt/homebrew/bin/python3 ]]; then
  python_bin=/opt/homebrew/bin/python3
elif [[ -z "$python_bin" ]] && command -v python3 >/dev/null 2>&1; then
  python_bin=$(command -v python3)
fi
if [[ -z "$python_bin" ]]; then
  printf 'Python 3.10 or newer is required to configure Codex.\n' >&2
  exit 1
fi
"$python_bin" "$repo_root/scripts/configure.py" \
  --renderer "$share_root/current/renderer/statusline.sh"

printf '\nNative Codex status line installed.\n'
printf 'Launch it with: codex-statusline\n'
printf 'The official codex command remains unchanged.\n'
