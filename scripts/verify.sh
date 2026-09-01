#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../upstream.lock
source "$repo_root/upstream.lock"

"$repo_root/tests/renderer-tests.sh"
"$repo_root/tests/configure-tests.sh"

if command -v shasum >/dev/null 2>&1; then
  actual_patch_sha=$(shasum -a 256 "$repo_root/patches/native-statusline.patch" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  actual_patch_sha=$(sha256sum "$repo_root/patches/native-statusline.patch" | awk '{print $1}')
else
  printf 'verification requires shasum or sha256sum\n' >&2
  exit 1
fi
[[ "$actual_patch_sha" == "$PATCH_SHA256" ]]

patch_check_root=$(mktemp -d)
trap 'rm -rf "$patch_check_root"' EXIT
printf 'checking patch against pinned upstream commit...\n'
git clone --quiet --filter=blob:none --no-checkout "$UPSTREAM_REPO" "$patch_check_root/upstream"
git -C "$patch_check_root/upstream" checkout --quiet --detach "$UPSTREAM_COMMIT"
git -C "$patch_check_root/upstream" apply --check "$repo_root/patches/native-statusline.patch"

bin_dir=${CODEX_STATUSLINE_BIN_DIR:-"${HOME}/.local/bin"}
if [[ -x "$bin_dir/codex-statusline" ]]; then
  actual_version=$("$bin_dir/codex-statusline" --version)
  [[ "$actual_version" == "codex-cli $EXPECTED_CLI_VERSION" ]]
fi

printf 'verification passed\n'
