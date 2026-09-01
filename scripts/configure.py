#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import stat
import tempfile
from pathlib import Path


SECTION = "tui.status_line_command"


def rendered_section(renderer: Path) -> str:
    quoted = str(renderer).replace("\\", "\\\\").replace('"', '\\"')
    return "\n".join(
        [
            f"[{SECTION}]",
            f'command = ["{quoted}"]',
            "refresh_interval_ms = 1000",
            "timeout_ms = 1000",
            "max_lines = 4",
        ]
    )


def update_config(config: Path, renderer: Path) -> None:
    original = config.read_text(encoding="utf-8") if config.exists() else ""
    section = rendered_section(renderer)
    pattern = re.compile(
        rf"(?ms)^\[{re.escape(SECTION)}\]\n.*?(?=^\[|\Z)"
    )
    without_existing_sections = pattern.sub("", original).rstrip()
    updated = (
        without_existing_sections
        + ("\n\n" if without_existing_sections else "")
        + section
        + "\n"
    )

    config.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(config.stat().st_mode) if config.exists() else 0o600
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=config.parent, delete=False
    ) as handle:
        handle.write(updated)
        temporary = Path(handle.name)
    os.chmod(temporary, mode)
    temporary.replace(config)


if __name__ == "__main__":
    home = Path.home()
    parser = argparse.ArgumentParser(description="Configure the native Codex status line")
    parser.add_argument(
        "--renderer",
        type=Path,
        default=home / ".local/share/codex-statusline/current/renderer/statusline.sh",
    )
    args = parser.parse_args()
    update_config(
        Path(os.environ.get("CODEX_HOME", home / ".codex")) / "config.toml",
        args.renderer.expanduser().resolve(),
    )
