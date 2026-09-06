#!/usr/bin/env python3
"""Open a GitHub issue for each newly added plugin.

Triggered by the same push-to-main workflow that rebuilds the catalog. Compares the
before/after commits of the push to find `*/plugin.toml` files that were added, and
opens one issue per new plugin directory, named after the directory itself.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[3]


def git_output(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def added_plugin_dirs(before: str, after: str) -> list[str]:
    """Directory names of every `plugin.toml` newly added between two commits."""
    if not before or not after or before == "0" * 40:
        # workflow_dispatch (no before/after) or first push of a new branch:
        # nothing safe to diff against, so treat nothing as "new".
        return []

    diff = git_output(
        "diff", "--diff-filter=A", "--name-only", before, after, "--", "*/plugin.toml"
    )
    dirs = []
    for line in diff.splitlines():
        line = line.strip()
        if line:
            dirs.append(Path(line).parent.name)
    return dirs


def load_manifest(directory: str) -> dict:
    manifest_path = ROOT_DIR / directory / "plugin.toml"
    with manifest_path.open("rb") as handle:
        return tomllib.load(handle)


def issue_already_exists(repo: str, title: str) -> bool:
    """True if an issue with this exact title already exists, open or closed.

    Guards against duplicate issues if this job is ever re-run for the same push
    (a manual re-run, for instance).
    """
    result = subprocess.run(
        [
            "gh", "issue", "list",
            "--repo", repo,
            "--state", "all",
            "--search", f'"{title}" in:title',
            "--json", "title",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    titles = {item["title"] for item in json.loads(result.stdout)}
    return title in titles


def create_issue(repo: str, directory: str, manifest: dict) -> None:
    title = directory
    name = manifest.get("name", directory)
    description = (manifest.get("description") or "").strip()
    version = manifest.get("version", "?")
    author = manifest.get("author", "?")

    body = "\n".join(
        [
            f"**Plugin:** {name}",
            f"**Version:** {version}",
            f"**Author:** {author}",
            "",
            description or "_No description provided._",
        ]
    )

    if issue_already_exists(repo, title):
        print(f"Issue already exists for {title!r}, skipping.")
        return

    subprocess.run(
        ["gh", "issue", "create", "--repo", repo, "--title", title, "--body", body],
        check=True,
    )
    print(f"Created issue for {title!r}.")


def main() -> int:
    repo = os.environ["GH_REPO"]
    before = os.environ.get("BEFORE_SHA", "")
    after = os.environ.get("AFTER_SHA", "")

    dirs = added_plugin_dirs(before, after)
    if not dirs:
        print("No new plugins in this push.")
        return 0

    for directory in dirs:
        try:
            manifest = load_manifest(directory)
        except (OSError, tomllib.TOMLDecodeError) as error:
            print(f"warning: could not read plugin.toml for {directory}: {error}", file=sys.stderr)
            continue
        create_issue(repo, directory, manifest)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
