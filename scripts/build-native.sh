#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../upstream.lock
source "$repo_root/upstream.lock"

for command_name in git rustup dotslash jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'missing build dependency: %s\n' "$command_name" >&2
    exit 1
  fi
done

python_bin=${CODEX_STATUSLINE_PYTHON:-}
if [[ -z "$python_bin" && -x /opt/homebrew/bin/python3 ]]; then
  python_bin=/opt/homebrew/bin/python3
elif [[ -z "$python_bin" ]] && command -v python3 >/dev/null 2>&1; then
  python_bin=$(command -v python3)
fi
if [[ -z "$python_bin" ]]; then
  printf 'Python 3.10 or newer is required to build Codex.\n' >&2
  exit 1
fi
if ! "$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  printf 'Python 3.10 or newer is required: %s\n' "$python_bin" >&2
  exit 1
fi

patch_file="$repo_root/patches/native-statusline.patch"
if command -v shasum >/dev/null 2>&1; then
  actual_patch_sha=$(shasum -a 256 "$patch_file" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  actual_patch_sha=$(sha256sum "$patch_file" | awk '{print $1}')
else
  printf 'build requires shasum or sha256sum\n' >&2
  exit 1
fi
if [[ "$actual_patch_sha" != "$PATCH_SHA256" ]]; then
  printf 'patch checksum mismatch: expected %s, got %s\n' "$PATCH_SHA256" "$actual_patch_sha" >&2
  exit 1
fi

build_root=${CODEX_STATUSLINE_BUILD_ROOT:-"${TMPDIR:-/tmp}/codex-statusline-build"}
mkdir -p "$build_root"
source_dir=$(mktemp -d "$build_root/source.XXXXXX")
staging_root=""
cleanup() {
  rm -rf "$source_dir"
  if [[ -n "$staging_root" && -d "$staging_root" ]]; then
    rm -rf "$staging_root"
  fi
}
trap cleanup EXIT

printf 'Cloning OpenAI Codex at %s...\n' "$UPSTREAM_COMMIT"
git clone --filter=blob:none --no-checkout "$UPSTREAM_REPO" "$source_dir"
git -C "$source_dir" checkout --detach "$UPSTREAM_COMMIT"
git -C "$source_dir" apply --check "$patch_file"
git -C "$source_dir" apply "$patch_file"

rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --component rustfmt --component clippy

release_name="${UPSTREAM_VERSION}+statusline.${PATCH_VERSION}"
coding_profile=${CODEX_STATUSLINE_CARGO_PROFILE:-release}
share_root=${CODEX_STATUSLINE_SHARE_ROOT:-"${HOME}/.local/share/codex-statusline"}
release_dir="$share_root/releases/$release_name"
if [[ -e "$release_dir" ]]; then
  printf 'release already exists: %s\n' "$release_dir" >&2
  exit 1
fi
mkdir -p "$(dirname "$release_dir")"
staging_root=$(mktemp -d "$share_root/.staging.${release_name}.XXXXXX")
staged_release="$staging_root/package"

printf 'Building native Codex package %s...\n' "$release_name"
CODEX_REPO_ROOT="$source_dir" RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" \
  "$python_bin" "$source_dir/scripts/build_codex_package.py" \
  --cargo-profile "$coding_profile" \
  --package-dir "$staged_release" \
  --package-version "$release_name"

mkdir -p "$staged_release/renderer" "$staged_release/THIRD_PARTY_NOTICES"
cp "$repo_root/renderer/statusline.sh" "$staged_release/renderer/statusline.sh"
cp "$repo_root/LICENSE" "$staged_release/LICENSE"
cp "$repo_root/THIRD_PARTY_NOTICES/"* "$staged_release/THIRD_PARTY_NOTICES/"
chmod +x "$staged_release/renderer/statusline.sh"

actual_version=$("$staged_release/bin/codex" --version)
if [[ "$actual_version" != "codex-cli $EXPECTED_CLI_VERSION" ]]; then
  printf 'unexpected Codex version: %s\n' "$actual_version" >&2
  exit 1
fi
if ! jq --arg cwd "$repo_root" '.cwd = $cwd' "$repo_root/tests/fixtures/status-payload.json" \
  | "$staged_release/renderer/statusline.sh" >/dev/null; then
  printf 'staged renderer smoke test failed\n' >&2
  exit 1
fi

mv "$staged_release" "$release_dir"
current_link="$staging_root/current"
ln -s "$release_dir" "$current_link"
mv -f -h "$current_link" "$share_root/current"
bin_dir=${CODEX_STATUSLINE_BIN_DIR:-"${HOME}/.local/bin"}
mkdir -p "$bin_dir"
launcher_link="$staging_root/launcher"
ln -s "$share_root/current/bin/codex" "$launcher_link"
mv -f -h "$launcher_link" "$bin_dir/codex-statusline"

printf 'Installed native build:\n'
printf '  %s\n' "$release_dir"
printf 'Launcher:\n'
printf '  %s\n' "$bin_dir/codex-statusline"
printf 'Renderer:\n'
printf '  %s\n' "$share_root/current/renderer/statusline.sh"
