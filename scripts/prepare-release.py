#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def get_json(url: str) -> dict:
    headers = {"User-Agent": "codex-statusline-builder"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> None:
    lock_path = ROOT / "upstream.lock"
    lock = dict(line.split("=", 1) for line in lock_path.read_text().splitlines() if line)
    latest = get_json("https://api.github.com/repos/openai/codex/releases/latest")
    tag = latest["tag_name"]
    if latest["draft"] or latest["prerelease"] or not re.fullmatch(r"rust-v\d+\.\d+\.\d+", tag):
        raise ValueError(f"Unexpected upstream release: {tag}")
    commit = get_json(f"https://api.github.com/repos/openai/codex/commits/{tag}")["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid upstream commit")
    version = tag.removeprefix("rust-v")
    lock["UPSTREAM_COMMIT"] = commit
    lock["UPSTREAM_VERSION"] = version
    lock["EXPECTED_CLI_VERSION"] = f"{version}-statusline.{lock['PATCH_VERSION']}"
    lock["PATCH_SHA256"] = hashlib.sha256((ROOT / "patches/native-statusline.patch").read_bytes()).hexdigest()
    with urllib.request.urlopen(f"https://raw.githubusercontent.com/openai/codex/{commit}/codex-rs/rust-toolchain.toml", timeout=30) as response:
        toolchain = re.search(r'^channel = "([0-9.]+)"$', response.read().decode(), re.MULTILINE)
    if toolchain is None:
        raise ValueError("Cannot determine upstream Rust toolchain")
    lock["RUST_TOOLCHAIN"] = toolchain.group(1)
    revision = os.environ["GITHUB_SHA"][:12]
    if not re.fullmatch(r"[0-9a-f]{12}", revision):
        raise ValueError("Invalid build revision")
    release = f"{version}+statusline.{lock['PATCH_VERSION']}.{revision}"
    lock_path.write_text("".join(f"{key}={value}\n" for key, value in lock.items()))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"tag=v{release}\nrelease={release}\n")
    print(f"Candidate: {release} at {commit}")


if __name__ == "__main__":
    main()
