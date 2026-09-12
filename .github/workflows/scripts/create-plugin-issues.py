#!/usr/bin/env python3
"""Keep one GitHub issue per plugin in sync with its plugin.toml.

Triggered by the push-to-main workflow. For EVERY plugin directory it makes sure an
open issue (named after the directory) reflects the current manifest: it creates one
for brand-new plugins, and edits the existing open one whenever name/version/date/
description change. Updates only happen when the body actually differs, so unrelated
pushes are no-ops.

The date shown right after the version is the commit date when that version string was
first released (from plugin.toml history); it moves forward when the version bumps.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tomllib
from datetime import datetime
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[3]

MONTHS = ["", "jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]


def git_output(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def gh(*args: str) -> str:
    return subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=True
    ).stdout


def format_date(timestamp: int) -> str:
    date = datetime.fromtimestamp(timestamp)
    return f"{date.day:02d} {MONTHS[date.month]} {date.year}"


def all_plugin_dirs() -> list[str]:
    """Every directory containing a plugin.toml, sorted."""
    return sorted(path.parent.name for path in ROOT_DIR.glob("*/plugin.toml"))


def load_manifest(directory: str) -> dict:
    manifest_path = ROOT_DIR / directory / "plugin.toml"
    with manifest_path.open("rb") as handle:
        return tomllib.load(handle)


def version_release_time(directory: str, version: str) -> int | None:
    """Commit time (unix) of the first commit that shipped `version`.

    Walks plugin.toml history oldest-first; the earliest commit carrying the version
    string is the bump that released it, matching update-catalog.py's `release_times`.
    """
    try:
        revisions = git_output(
            "log", "--format=%H %ct", "--", f"{directory}/plugin.toml"
        ).splitlines()
    except subprocess.CalledProcessError:
        return None

    for line in reversed(revisions):
        revision, _, commit_time = line.partition(" ")
        try:
            manifest_at = tomllib.loads(
                git_output("show", f"{revision}:{directory}/plugin.toml")
            )
        except (subprocess.CalledProcessError, tomllib.TOMLDecodeError):
            continue
        if manifest_at.get("version") == version:
            return int(commit_time)
    return None


def plugin_timestamp(directory: str, version: str) -> int:
    """Release date of the current version; falls back to the manifest's commit or mtime."""
    release = version_release_time(directory, version)
    if release is not None:
        return release
    try:
        commit = git_output("log", "-1", "--format=%ct", "--", f"{directory}/plugin.toml").strip()
        if commit:
            return int(commit)
    except (subprocess.CalledProcessError, ValueError):
        pass
    return int((ROOT_DIR / directory / "plugin.toml").stat().st_mtime)


def issue_body(directory: str, manifest: dict) -> str:
    name = manifest.get("name", directory)
    description = (manifest.get("description") or "").strip()
    version = str(manifest.get("version", "?"))
    author = manifest.get("author", "?")
    date = format_date(plugin_timestamp(directory, version))

    return "\n".join(
        [
            f"**Plugin:** {name}",
            f"**Version:** {version}",
            f"**Date:** {date}",
            f"**Author:** {author}",
            "",
            description or "_No description provided._",
        ]
    )


def list_issues(repo: str) -> tuple[dict[str, dict], set[str]]:
    """Open issues keyed by title, plus the set of every title (open or closed)."""
    result = gh(
        "issue", "list", "--repo", repo, "--state", "all",
        "--limit", "500", "--json", "number,title,body,state",
    )
    issues = json.loads(result)
    open_by_title = {
        item["title"]: item for item in issues if item.get("state") == "OPEN"
    }
    all_titles = {item["title"] for item in issues}
    return open_by_title, all_titles


def sync_issue(
    repo: str,
    directory: str,
    manifest: dict,
    open_by_title: dict[str, dict],
    all_titles: set[str],
) -> str:
    title = directory
    body = issue_body(directory, manifest)

    existing_open = open_by_title.get(title)
    if existing_open is not None:
        current_body = (existing_open.get("body") or "").strip()
        if current_body == body:
            return f"'{title}' is already up to date."
        gh("issue", "edit", str(existing_open["number"]), "--repo", repo, "--body", body)
        return f"Updated issue for '{title}' (body changed)."

    if title in all_titles:
        return f"Issue for '{title}' exists but is closed; leaving it untouched."

    gh("issue", "create", "--repo", repo, "--title", title, "--body", body)
    return f"Created issue for '{title}'."


def main() -> int:
    repo = os.environ["GH_REPO"]

    dirs = all_plugin_dirs()
    if not dirs:
        print("No plugin directories found; nothing to do.")
        return 0

    open_by_title, all_titles = list_issues(repo)
    for directory in dirs:
        try:
            manifest = load_manifest(directory)
        except (OSError, tomllib.TOMLDecodeError) as error:
            print(f"warning: could not read plugin.toml for {directory}: {error}", file=sys.stderr)
            continue
        print(sync_issue(repo, directory, manifest, open_by_title, all_titles))

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)