#!/usr/bin/env bash
set -euo pipefail
export GIT_TERMINAL_PROMPT=0

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
  printf 'Python 3.12 or newer is required to build Codex.\n' >&2
  exit 1
fi
if ! "$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))'; then
  printf 'Python 3.12 or newer is required: %s\n' "$python_bin" >&2
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

"$python_bin" - "$source_dir/codex-rs/cli/Cargo.toml" "$EXPECTED_CLI_VERSION" <<'PY'
import pathlib
import re
import sys
manifest = pathlib.Path(sys.argv[1])
text, count = re.subn(r'^version(?:\.workspace = true| = "[^"]+")$',
                      f'version = "{sys.argv[2]}"', manifest.read_text(), count=1, flags=re.MULTILINE)
if count != 1:
    raise SystemExit("Cannot set CLI package version")
manifest.write_text(text)
PY

rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --component rustfmt --component clippy

coding_profile=${CODEX_STATUSLINE_CARGO_PROFILE:-release}
if [[ ${CODEX_STATUSLINE_NATIVE_TESTS:-0} == 1 ]]; then
  (
    cd "$source_dir/codex-rs"
    native_target=$(rustc +"$RUST_TOOLCHAIN" -vV | awk '/^host:/ {print $2}')
    RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" just test -p codex-tui --lib \
      --cargo-profile dev --target "$native_target" \
      -E 'test(bottom_pane::) | test(status_line) | test(multiline_status) | test(status_surface) | test(side_context_label_shows_parent_status)'
  )
fi

release_name=${CODEX_STATUSLINE_RELEASE_NAME:-"${UPSTREAM_VERSION}+statusline.${PATCH_VERSION}"}
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
mkdir -p "$staged_release/updater"
cp "$repo_root/scripts/update.py" "$staged_release/updater/update.py"
cp "$repo_root/renderer/statusline.sh" "$staged_release/renderer/statusline.sh"
cp "$repo_root/LICENSE" "$staged_release/LICENSE"
cp "$repo_root/THIRD_PARTY_NOTICES/"* "$staged_release/THIRD_PARTY_NOTICES/"
chmod +x "$staged_release/renderer/statusline.sh"
"$python_bin" - "$staged_release" "$release_name" "$EXPECTED_CLI_VERSION" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1], "statusline-release.json").write_text(json.dumps({
    "version": sys.argv[2], "cli_version": sys.argv[3], "source_build": True,
}) + "\n")
PY

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
if [[ ${CODEX_STATUSLINE_ACTIVATE:-1} == 0 ]]; then
  printf 'Built package: %s\n' "$release_dir"
  exit 0
fi
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
