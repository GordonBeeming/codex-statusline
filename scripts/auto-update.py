#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path


LABEL = "com.gordonbeeming.codex-statusline.update"


def main() -> None:
    parser = argparse.ArgumentParser(description="Enable or disable six-hourly macOS release updates")
    parser.add_argument("action", choices=["enable", "disable"])
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Automatic updates currently support Apple Silicon macOS only")
    if sys.version_info < (3, 12):
        parser.error("Python 3.12 or newer is required for safe archive extraction")
    share = Path(os.environ.get("CODEX_STATUSLINE_SHARE_ROOT", Path.home() / ".local/share/codex-statusline")).expanduser().absolute()
    bin_dir = Path(os.environ.get("CODEX_STATUSLINE_BIN_DIR", Path.home() / ".local/bin")).expanduser().absolute()
    agent = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    loaded = subprocess.run(["launchctl", "print", f"{domain}/{LABEL}"], capture_output=True).returncode == 0
    if loaded:
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], check=True)
        for attempt in range(20):
            if subprocess.run(["launchctl", "print", f"{domain}/{LABEL}"], capture_output=True).returncode != 0:
                break
            time.sleep(0.25)
        else:
            parser.error("Previous updater is still stopping; retry shortly")
    if args.action == "disable":
        agent.unlink(missing_ok=True)
        print("Automatic updates disabled.")
        return
    share.mkdir(parents=True, exist_ok=True)
    updater = share / "update.py"
    packaged_updater = share / "current/updater/update.py"
    source = packaged_updater if packaged_updater.is_file() else Path(__file__).with_name("update.py")
    shutil.copyfile(source, updater)
    agent.parent.mkdir(parents=True, exist_ok=True)
    environment_path = os.environ.get("PATH", "/usr/bin:/bin")
    agent.write_bytes(plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": [sys.executable, str(updater), "--share-root", str(share), "--bin-dir", str(bin_dir)],
        "StartInterval": 21600,
        "RunAtLoad": True,
        "ProcessType": "Background",
        "EnvironmentVariables": {"PATH": environment_path},
        "StandardOutPath": str(share / "update.log"),
        "StandardErrorPath": str(share / "update-error.log"),
    }))
    subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
    print(f"Automatic updates enabled. Logs: {share / 'update.log'}")


if __name__ == "__main__":
    main()
