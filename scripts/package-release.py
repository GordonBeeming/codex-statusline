#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    lock_path = Path(__file__).resolve().parent.parent / "upstream.lock"
    lock = dict(line.split("=", 1) for line in lock_path.read_text().splitlines() if line)
    args.output.mkdir(parents=True, exist_ok=True)
    platform = "aarch64-apple-darwin"
    archive = args.output / f"codex-statusline-{platform}.tar.gz"
    with tarfile.open(archive, "w:gz") as package:
        for path in sorted(args.package.iterdir()):
            package.add(path, arcname=path.name)
    digest = hashlib.sha256()
    with archive.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    manifest = {
        "version": args.version,
        "tag": f"v{args.version}",
        "platform": platform,
        "cli_version": lock["EXPECTED_CLI_VERSION"],
        "upstream_commit": lock["UPSTREAM_COMMIT"],
        "patch_sha256": lock["PATCH_SHA256"],
        "sha256": digest.hexdigest(),
    }
    (args.output / f"{platform}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output / "upstream.lock").write_bytes(lock_path.read_bytes())


if __name__ == "__main__":
    main()
