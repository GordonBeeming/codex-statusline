#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../upstream.lock
source "$repo_root/upstream.lock"

for command_name in git rustup just dotslash shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'missing build dependency: %s\n' "$command_name" >&2
    exit 1
  fi
done

python_bin=${CODEX_STATUSLINE_PYTHON:-}
if [[ -z "$python_bin" && -x /opt/homebrew/bin/python3 ]]; then
  python_bin=/opt/homebrew/bin/python3
elif [[ -z "$python_bin" ]]; then
  python_bin=$(command -v python3)
fi
if ! "$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  printf 'Python 3.10 or newer is required: %s\n' "$python_bin" >&2
  exit 1
fi

patch_file="$repo_root/patches/native-statusline.patch"
actual_patch_sha=$(shasum -a 256 "$patch_file" | awk '{print $1}')
if [[ "$actual_patch_sha" != "$PATCH_SHA256" ]]; then
  printf 'patch checksum mismatch: expected %s, got %s\n' "$PATCH_SHA256" "$actual_patch_sha" >&2
  exit 1
fi

build_root=${CODEX_STATUSLINE_BUILD_ROOT:-"${TMPDIR:-/tmp}/codex-statusline-build"}
mkdir -p "$build_root"
source_dir=$(mktemp -d "$build_root/source.XXXXXX")
cleanup() {
  rm -rf "$source_dir"
}
trap cleanup EXIT

printf 'Cloning OpenAI Codex at %s...\n' "$UPSTREAM_COMMIT"
git clone --filter=blob:none --no-checkout "$UPSTREAM_REPO" "$source_dir"
git -C "$source_dir" checkout --detach "$UPSTREAM_COMMIT"
git -C "$source_dir" apply --check "$patch_file"
git -C "$source_dir" apply "$patch_file"

rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --component rustfmt --component clippy

release_name="${UPSTREAM_VERSION}+statusline.${PATCH_VERSION}"
coding_profile=${CODEX_STATUSLINE_CARGO_PROFILE:-dev}
share_root=${CODEX_STATUSLINE_SHARE_ROOT:-"${HOME}/.local/share/codex-statusline"}
release_dir="$share_root/releases/$release_name"
if [[ -e "$release_dir" ]]; then
  printf 'release already exists: %s\n' "$release_dir" >&2
  exit 1
fi
mkdir -p "$(dirname "$release_dir")"

printf 'Building native Codex package %s...\n' "$release_name"
CODEX_REPO_ROOT="$source_dir" RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" \
  "$python_bin" "$source_dir/scripts/build_codex_package.py" \
  --cargo-profile "$coding_profile" \
  --package-dir "$release_dir" \
  --package-version "$release_name"

mkdir -p "$release_dir/renderer" "${HOME}/.local/bin"
cp "$repo_root/renderer/statusline.sh" "$release_dir/renderer/statusline.sh"
chmod +x "$release_dir/renderer/statusline.sh"
ln -sfn "$release_dir" "$share_root/current"
ln -sfn "$share_root/current/bin/codex" "${HOME}/.local/bin/codex-statusline"

printf 'Installed native build:\n'
printf '  %s\n' "$release_dir"
printf 'Launcher:\n'
printf '  %s\n' "${HOME}/.local/bin/codex-statusline"
printf 'Renderer:\n'
printf '  %s\n' "$share_root/current/renderer/statusline.sh"
