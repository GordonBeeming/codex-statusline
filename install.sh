#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${CODEX_HOME:-${HOME}/.codex}/scripts"
SCRIPT_NAME="codex-statusline.sh"
BIN_DIR="${HOME}/.local/bin"
SHORTCUT_NAME="cs"
CURRENCY_CONFIG="${CODEX_STATUSLINE_CURRENCY_CONFIG:-${HOME}/.codex-statusline.json}"

echo "=== Codex Statusline Installer ==="
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required."
  echo "Install it with: brew install jq"
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 is required."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing ${SCRIPT_NAME} to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp "${SCRIPT_DIR}/statusline.sh" "${INSTALL_DIR}/${SCRIPT_NAME}"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"

echo "Installing ${SHORTCUT_NAME} shortcut to ${BIN_DIR}..."
mkdir -p "$BIN_DIR"
ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${BIN_DIR}/${SHORTCUT_NAME}"

if [[ ! -f "$CURRENCY_CONFIG" ]]; then
  echo "Creating AUD currency config at ${CURRENCY_CONFIG}..."
  jq -n '{currency: "AUD"}' > "$CURRENCY_CONFIG"
fi

echo ""
echo "Installed:"
echo "  ${INSTALL_DIR}/${SCRIPT_NAME}"
echo "  ${BIN_DIR}/${SHORTCUT_NAME}"
echo ""
echo "Run it any time with:"
echo "  ${SHORTCUT_NAME}"
echo ""
echo "Codex currently configures the TUI footer with built-in status item IDs."
echo "Codex does not currently expose user-defined slash commands, so use ${SHORTCUT_NAME} instead of /${SHORTCUT_NAME}."
echo "Add this to ~/.codex/config.toml for the closest native Codex footer:"
echo ""
echo '[tui]'
echo 'status_line = ["model-with-reasoning", "context-remaining", "current-dir", "git-branch"]'
echo 'terminal_title = ["spinner", "project"]'
echo ""
echo "The enhanced AUD cost/status output is provided by the installed script."
