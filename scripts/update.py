#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import uuid
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath


REPOSITORY = "GordonBeeming/codex-statusline"
API = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
PLATFORM = "aarch64-apple-darwin"


def download(url: str, destination: Path) -> None:
    if not url.startswith(f"https://github.com/{REPOSITORY}/releases/download/"):
        raise ValueError("Unexpected release asset URL")
    request = urllib.request.Request(url, headers={"User-Agent": "codex-statusline-updater"})
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def extract(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, "r:gz") as package:
        for member in package.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"Unsafe archive path: {member.name}")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f"Unsupported archive entry: {member.name}")
            target = destination / member.name
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError(f"Archive path escapes package: {member.name}")
            if member.issym():
                link = Path(member.linkname)
                if link.is_absolute() or not (target.parent / link).resolve().is_relative_to(destination.resolve()):
                    raise ValueError(f"Unsafe archive symlink: {member.name}")
            package.extract(member, destination, filter="data")


def switch_link(link: Path, target: Path) -> None:
    link.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".link-", dir=link.parent) as temporary:
        staged = Path(temporary) / "link"
        staged.symlink_to(target)
        staged.replace(link)


def installed_manifest(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def cli_version_components(value: object) -> tuple[int, ...] | None:
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)-statusline\.(\d+)", value)
    return tuple(int(part) for part in match.groups()) if match else None


def validate_package(package: Path, expected: str) -> None:
    result = subprocess.run([str(package / "bin/codex"), "--version"],
                            check=True, capture_output=True, text=True, timeout=30)
    if result.stdout.strip() != f"codex-cli {expected}":
        raise ValueError("Downloaded CLI version mismatch")
    payload = json.dumps({
        "schema_version": 1,
        "cwd": str(package),
        "model": {"display_name": "Codex"},
        "rate_limits": [{"primary": {"window_minutes": 300, "used_percentage": 0}}],
    })
    subprocess.run([str(package / "renderer/statusline.sh")], input=payload,
                   check=True, capture_output=True, text=True, timeout=10)


def activate(release: Path, share: Path, bin_dir: Path) -> None:
    current = share / "current"
    if current.is_symlink() and current.resolve() != release.resolve():
        switch_link(share / "previous", current.resolve())
    switch_link(bin_dir / "codex-statusline", current / "bin/codex")
    packaged_updater = release / "updater/update.py"
    if packaged_updater.is_file():
        with tempfile.TemporaryDirectory(prefix=".updater-", dir=share) as temporary:
            staged = Path(temporary) / "update.py"
            shutil.copyfile(packaged_updater, staged)
            staged.replace(share / "update.py")
    switch_link(current, release)


def install_archive(archive: Path, manifest: dict, share: Path, bin_dir: Path) -> None:
    if not isinstance(manifest, dict):
        raise ValueError("Release manifest must be an object")
    version = manifest.get("version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+\+statusline\.\d+\.[0-9a-f]{12}", version):
        raise ValueError("Invalid release version")
    if manifest.get("platform") != PLATFORM:
        raise ValueError("Release platform mismatch")
    expected = manifest.get("cli_version", "")
    if cli_version_components(expected) is None:
        raise ValueError("Invalid CLI version")
    digest = hashlib.sha256()
    with archive.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != manifest.get("sha256"):
        raise ValueError("Release checksum mismatch")
    releases = share / "releases"
    releases.mkdir(parents=True, exist_ok=True)
    release = releases / version
    with tempfile.TemporaryDirectory(prefix=".update-", dir=share) as temporary:
        staged = Path(temporary) / "package"
        staged.mkdir()
        extract(archive, staged)
        validate_package(staged, expected)
        (staged / "statusline-release.json").write_text(json.dumps(manifest) + "\n")
        if release.exists():
            reusable = installed_manifest(release / "statusline-release.json") == manifest
            if reusable:
                try:
                    validate_package(release, expected)
                except (OSError, ValueError, subprocess.SubprocessError):
                    reusable = False
            if not reusable:
                release = releases / f"{version}.repair-{uuid.uuid4().hex}"
                staged.rename(release)
        else:
            staged.rename(release)
    activate(release, share, bin_dir)
    print(f"Installed {version}. New sessions will use it.")


def update(share: Path, bin_dir: Path) -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Prebuilt updates currently support Apple Silicon macOS only")
    share.mkdir(parents=True, exist_ok=True)
    with (share / ".update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another update is already running.")
            return
        request = urllib.request.Request(API, headers={"User-Agent": "codex-statusline-updater"})
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
        if release.get("draft") or release.get("prerelease"):
            raise ValueError("Expected a stable public release")
        assets = {asset["name"]: asset["browser_download_url"] for asset in release["assets"]}
        with tempfile.TemporaryDirectory(prefix=".download-", dir=share) as temporary:
            manifest_file = Path(temporary) / "release.json"
            download(assets[f"{PLATFORM}.json"], manifest_file)
            manifest = json.loads(manifest_file.read_text())
            if not isinstance(manifest, dict):
                raise ValueError("Release manifest must be an object")
            if manifest.get("tag") != release["tag_name"]:
                raise ValueError("Release tag mismatch")
            installed_file = share / "current/statusline-release.json"
            installed = installed_manifest(installed_file)
            if installed:
                if installed == manifest:
                    try:
                        validate_package(share / "current", manifest["cli_version"])
                    except (OSError, ValueError, subprocess.SubprocessError):
                        print("Installed package failed validation; downloading a replacement.")
                    else:
                        activate((share / "current").resolve(), share, bin_dir)
                        print(f"Already current: {installed['version']}")
                        return
                candidate_version = cli_version_components(manifest.get("cli_version"))
                current_version = cli_version_components(installed.get("cli_version"))
                if candidate_version is None:
                    raise ValueError("Invalid CLI version")
                if current_version is not None and candidate_version < current_version:
                    raise ValueError("Refusing a CLI version downgrade")
            archive = Path(temporary) / "package.tar.gz"
            download(assets[f"codex-statusline-{PLATFORM}.tar.gz"], archive)
            install_archive(archive, manifest, share, bin_dir)


def main() -> None:
    parser = argparse.ArgumentParser(description="Install the latest verified codex-statusline release")
    parser.add_argument("--share-root", type=Path, default=Path.home() / ".local/share/codex-statusline")
    parser.add_argument("--bin-dir", type=Path, default=Path.home() / ".local/bin")
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error("Python 3.12 or newer is required for safe archive extraction")
    try:
        update(args.share_root.expanduser().absolute(), args.bin_dir.expanduser().absolute())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, f"Update failed; existing installation retained: {error}\n")


if __name__ == "__main__":
    main()
