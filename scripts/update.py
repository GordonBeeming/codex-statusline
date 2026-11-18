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
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath


REPOSITORY = "GordonBeeming/codex-statusline"
API = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
PLATFORM = "aarch64-apple-darwin"


def latest_tag(repository: str) -> str:
    request = urllib.request.Request(
        f"https://github.com/{repository}/releases/latest",
        headers={"User-Agent": "codex-statusline-updater"}, method="HEAD",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        resolved = response.geturl()
    prefix = f"https://github.com/{repository}/releases/tag/"
    if not resolved.startswith(prefix):
        raise ValueError(f"Unexpected latest release URL for {repository}")
    return urllib.parse.unquote(resolved.removeprefix(prefix))


def latest_upstream_version() -> tuple[int, ...]:
    tag = latest_tag("openai/codex")
    match = re.fullmatch(r"rust-v(\d+)\.(\d+)\.(\d+)", tag)
    if match is None:
        raise ValueError(f"Unexpected upstream release tag: {tag}")
    return tuple(int(part) for part in match.groups())


def verify_upstream_freshness(manifest: dict, share: Path) -> bool:
    version = cli_version_components(manifest.get("cli_version"))
    if version is None:
        raise ValueError("Invalid CLI version")
    upstream = latest_upstream_version()
    latest = ".".join(map(str, upstream))
    now = time.time()
    health_file = share / "update-health.json"
    previous = installed_manifest(health_file) or {}
    first_seen = previous.get("first_seen", now) if previous.get("upstream_version") == latest else now
    if not isinstance(first_seen, (int, float)) or not 0 <= first_seen <= now:
        first_seen = now
    behind = upstream > version[:3]
    multiple_releases = (
        upstream[:2] > (version[0], version[1] + 1)
        or (upstream[:2] == version[:2] and upstream[2] > version[2] + 1)
    )
    blocked = behind and (multiple_releases or now - first_seen >= 12 * 3600)
    health = {
        "upstream_version": latest, "package_version": manifest["cli_version"],
        "first_seen": first_seen, "checked_at": now,
        "status": "blocked" if blocked else "pending" if behind else "current",
    }
    with tempfile.TemporaryDirectory(prefix=".health-", dir=share) as temporary:
        staged = Path(temporary) / "health.json"
        staged.write_text(json.dumps(health) + "\n")
        staged.replace(health_file)
    if blocked:
        raise ValueError(
            f"Upstream Codex {latest} is newer than the latest statusline package "
            f"({manifest['cli_version']}); the release pipeline needs attention: "
            f"https://github.com/{REPOSITORY}/actions/workflows/release.yml"
        )
    if behind:
        print(f"Latest statusline package installed; waiting for upstream Codex {latest} "
              "to pass the release pipeline (12-hour grace period).", file=sys.stderr)
    return not behind


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


def activate(release: Path, share: Path, bin_dir: Path, preserve_previous: bool = False) -> None:
    current = share / "current"
    if not preserve_previous and current.is_symlink() and current.resolve() != release.resolve():
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
    current_name = (share / "current").resolve().name
    repairing_current = current_name == version or current_name.startswith(f"{version}.repair-")
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
    activate(release, share, bin_dir, preserve_previous=repairing_current)
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
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                release = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code not in (403, 429):
                raise
            error.close()
            # Public release redirects do not consume the API's shared IP quota.
            tag = latest_tag(REPOSITORY)
            if not re.fullmatch(r"v\d+\.\d+\.\d+\+statusline\.\d+\.[0-9a-f]{12}", tag):
                raise ValueError("Invalid latest statusline release tag") from error
            base = f"https://github.com/{REPOSITORY}/releases/download/{urllib.parse.quote(tag, safe='')}/"
            release = {"tag_name": tag, "assets": [
                {"name": name, "browser_download_url": base + name}
                for name in (f"{PLATFORM}.json", f"codex-statusline-{PLATFORM}.tar.gz")
            ]}
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
                        if verify_upstream_freshness(manifest, share):
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
            verify_upstream_freshness(manifest, share)


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
        parser.exit(1, f"Update check failed: {error}\n")


if __name__ == "__main__":
    main()
