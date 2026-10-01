#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
from_source=0
auto_update=0
for argument in "$@"; do
  case "$argument" in
    --source) from_source=1 ;;
    --auto-update) auto_update=1 ;;
    *) printf 'Usage: %s [--source] [--auto-update]\n' "$0" >&2; exit 2 ;;
  esac
done
share_root=${CODEX_STATUSLINE_SHARE_ROOT:-"${HOME}/.local/share/codex-statusline"}
python_bin=${CODEX_STATUSLINE_PYTHON:-}
if [[ -z "$python_bin" && -x /opt/homebrew/bin/python3 ]]; then
  python_bin=/opt/homebrew/bin/python3
elif [[ -z "$python_bin" ]] && command -v python3 >/dev/null 2>&1; then
  python_bin=$(command -v python3)
fi
if [[ -z "$python_bin" ]]; then
  printf 'Python 3.12 or newer is required to install Codex updates.\n' >&2
  exit 1
fi
if [[ "$from_source" == 1 ]]; then
  "$repo_root/scripts/build-native.sh"
else
  "$python_bin" "$repo_root/scripts/update.py" --share-root "$share_root" \
    --bin-dir "${CODEX_STATUSLINE_BIN_DIR:-${HOME}/.local/bin}"
fi
"$python_bin" "$repo_root/scripts/configure.py" \
  --renderer "$share_root/current/renderer/statusline.sh"
if [[ "$auto_update" == 1 ]]; then
  "$python_bin" "$repo_root/scripts/auto-update.py" enable
fi

printf '\nNative Codex status line installed.\n'
printf 'Launch it with: codex-statusline\n'
printf 'The official codex command remains unchanged.\n'
