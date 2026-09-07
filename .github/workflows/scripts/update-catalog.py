#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
import tomllib
from pathlib import Path
from datetime import datetime, timezone


ROOT_DIR = Path(__file__).resolve().parents[3]
CATALOG_PATH = ROOT_DIR / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)

# Oldest plugin API any supported Noctalia accepts (kOldestSupportedPluginApiVersion in the
# shell's src/scripting/plugin_api.h). Release rows below it can never be installed, so the
# history walk stops there.
OLDEST_SUPPORTED_PLUGIN_API = 3


def git_commit_time(path: Path, *extra_args: str) -> int | None:
    """Commit time in Unix seconds, or None when `path` has no matching commit.

    An uncommitted plugin has no history, so `git log` prints nothing.
    """
    try:
        stdout = subprocess.run(
            ["git", "log", "-1", *extra_args, "--format=%ct", "--", str(path)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        return int(stdout) if stdout else None
    except (subprocess.CalledProcessError, ValueError):
        return None


def git_output(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def get_current_timestamp() -> int:
    """Get current Unix timestamp"""
    return int(datetime.now(timezone.utc).timestamp())


def plugin_history(subdir: str) -> list[tuple[str, int, dict]]:
    """Every readable revision of `<subdir>/plugin.toml`, newest first.

    One `git show` per revision, and both the release ladder and the per-version release
    dates come out of this single walk. (A directory rename starts the history over, the
    same way it resets `added_at`.)
    """
    history = []
    try:
        revisions = git_output(
            "log", "--format=%H %ct", "--", f"{subdir}/plugin.toml"
        ).splitlines()
    except subprocess.CalledProcessError:
        return history

    for line in revisions:
        revision, _, commit_time = line.partition(" ")
        try:
            manifest = tomllib.loads(
                git_output("show", f"{revision}:{subdir}/plugin.toml")
            )
        except (subprocess.CalledProcessError, tomllib.TOMLDecodeError):
            continue  # unreadable or pre-`plugin_api` history
        history.append((revision, int(commit_time), manifest))

    return history


def release_times(history: list[tuple[str, int, dict]]) -> dict[str, int]:
    """When each version string was first committed, keyed by version.

    The earliest commit carrying a version is the bump that released it. A later commit
    editing plugin.toml without bumping (tags, description, translations) must not move the
    date, and a version that reappears after a revert keeps its original one.
    """
    times: dict[str, int] = {}
    for _, commit_time, manifest in reversed(history):  # oldest first
        version = manifest.get("version")
        if isinstance(version, str) and version:
            if version not in times:
                print(f"DEBUG: Found version {version} with timestamp {commit_time}")
            times.setdefault(version, commit_time)
    return times


def release_history(
    history: list[tuple[str, int, dict]], tip_api: int, released: dict[str, int]
) -> list[dict]:
    """Older revisions of a plugin, one per API level below the tip's, newest first.

    A Noctalia below the tip's `plugin_api` has nothing to install unless the catalog names
    a revision it can run. Walking `<subdir>/plugin.toml` newest-first and keeping only the
    revisions that lower the API level yields a strictly decreasing sequence, so each row is
    the newest revision at or below its own level -- exactly what the host resolves against.
    """
    releases = []
    lowest_api = tip_api

    for revision, _, manifest in history:
        if lowest_api <= OLDEST_SUPPORTED_PLUGIN_API:
            break

        plugin_api = manifest.get("plugin_api")
        version = manifest.get("version")
        if not isinstance(plugin_api, int) or isinstance(plugin_api, bool):
            continue
        if not isinstance(version, str) or not version:
            continue
        if plugin_api >= lowest_api or plugin_api < OLDEST_SUPPORTED_PLUGIN_API:
            continue

        # `rev` is the newest revision still on this API level, not necessarily the bump
        # commit, so the date comes from the version rather than from `rev` itself.
        release_time = released.get(version, get_current_timestamp())
        releases.append(
            {
                "plugin_api": plugin_api,
                "version": version,
                "rev": revision,
                "updated_at": release_time,
            }
        )
        lowest_api = plugin_api

    return releases


def load_plugin_manifest(path: Path) -> dict:
    with path.open("rb") as handle:
        manifest = tomllib.load(handle)

    missing = [field for field in REQUIRED_FIELDS if field not in manifest]
    if missing:
        missing_fields = ", ".join(missing)
        raise ValueError(f"{path.relative_to(ROOT_DIR)} is missing: {missing_fields}")

    plugin_api = manifest["plugin_api"]
    if not isinstance(plugin_api, int) or isinstance(plugin_api, bool) or plugin_api <= 0:
        raise ValueError(
            f"{path.relative_to(ROOT_DIR)} has invalid plugin_api; expected a positive integer"
        )

    if not isinstance(manifest["tags"], list) or not all(
        isinstance(tag, str) for tag in manifest["tags"]
    ):
        raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid tags; expected strings")

    out = {field: manifest[field] for field in REQUIRED_FIELDS}
    for field in OPTIONAL_STRING_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], str):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid {field}; expected string")
            out[field] = manifest[field]
    for field in OPTIONAL_BOOL_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], bool):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid {field}; expected bool")
            out[field] = manifest[field]

    # Get commit time or fallback to file mtime
    mtime = int(path.stat().st_mtime)
    commit_time = git_commit_time(path)
    
    # If no commit time found, use mtime
    if commit_time is None:
        print(f"WARNING: No commit found for {path.relative_to(ROOT_DIR)}, using mtime")
        commit_time = mtime
    
    out["updated_at"] = commit_time
    out["added_at"] = git_commit_time(path, "--diff-filter=A") or out["updated_at"]
    
    print(f"DEBUG: {path.relative_to(ROOT_DIR)} - commit_time: {commit_time}, mtime: {mtime}")

    return out


def existing_catalog_order() -> dict[str, int]:
    if not CATALOG_PATH.exists():
        return {}

    content = CATALOG_PATH.read_text(encoding="utf-8")
    ids = re.findall(r'(?m)^id\s*=\s*"([^"]+)"', content)
    return {plugin_id: index for index, plugin_id in enumerate(ids)}


def discover_plugins() -> list[dict]:
    order = existing_catalog_order()
    plugins = []

    for manifest_path in sorted(ROOT_DIR.glob("*/plugin.toml")):
        try:
            manifest = load_plugin_manifest(manifest_path)
            directory = manifest_path.parent.name
            history = plugin_history(directory)
            released = release_times(history)
            manifest["_directory"] = directory
            manifest["_order"] = order.get(manifest["id"], len(order))
            
            # Update timestamp with release time if available, otherwise keep what we have
            if manifest["version"] in released:
                manifest["updated_at"] = released[manifest["version"]]
                print(f"DEBUG: Updated timestamp for {manifest['version']} to {manifest['updated_at']}")
            else:
                print(f"WARNING: Version {manifest['version']} not found in release history for {directory}")
                # Use current time if version is not in history (new version)
                if not history:
                    manifest["updated_at"] = get_current_timestamp()
                    print(f"DEBUG: Using current timestamp for new version {manifest['version']}")
            
            manifest["releases"] = release_history(history, manifest["plugin_api"], released)
            plugins.append(manifest)
        except Exception as e:
            print(f"ERROR processing {manifest_path}: {e}", file=sys.stderr)
            continue

    plugins.sort(key=lambda plugin: (plugin["_order"], plugin["_directory"]))
    return plugins


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_bool(value: bool) -> str:
    return "true" if value else "false"


def render_catalog(plugins: list[dict]) -> str:
    lines = [
        "# This file is auto-generated. Do not edit manually.",
        "# Do not include it in your commit.",
        "# Noctalia plugins catalog.",
        "# Index of every plugin this source ships: the minimum needed to render, search,",
        "# and compat-check the list. The per-plugin plugin.toml stays authoritative; the",
        "# host re-reads it on enable. Keep one [[plugin]] row per plugin subdirectory.",
        "# A [[plugin.release]] row names an older revision for a Noctalia below the tip's",
        "# plugin_api, so an older release stays installable instead of the plugin vanishing.",
        "# On every row, updated_at dates the commit that first shipped that row's version.",
        "",
    ]

    for index, plugin in enumerate(plugins):
        if index:
            lines.append("")

        lines.extend(
            [
                "[[plugin]]",
                f"id = {toml_string(plugin['id'])}",
                f"name = {toml_string(plugin['name'])}",
                f"version = {toml_string(plugin['version'])}",
                f"updated_at = {plugin['updated_at']}",
                f"added_at = {plugin['added_at']}",
                f"author = {toml_string(plugin['author'])}",
            ]
        )
        if "license" in plugin:
            lines.append(f"license = {toml_string(plugin['license'])}")
        if "icon" in plugin:
            lines.append(f"icon = {toml_string(plugin['icon'])}")
        if "description" in plugin:
            lines.append(f"description = {toml_string(plugin['description'])}")
        if "deprecated" in plugin:
            lines.append(f"deprecated = {toml_bool(plugin['deprecated'])}")
        lines.extend(
            [
                f"plugin_api = {plugin['plugin_api']}",
                "tags = ["
                + ", ".join(toml_string(tag) for tag in plugin["tags"])
                + "]",
            ]
        )
        for release in plugin["releases"]:
            lines.extend(
                [
                    "",
                    "[[plugin.release]]",
                    f"plugin_api = {release['plugin_api']}",
                    f"version = {toml_string(release['version'])}",
                    f"updated_at = {release['updated_at']}",
                    f"rev = {toml_string(release['rev'])}",
                ]
            )

    return "\n".join(lines) + "\n"


def main() -> int:
    try:
        plugins = discover_plugins()
        CATALOG_PATH.write_text(render_catalog(plugins), encoding="utf-8")
        print(f"Updated {CATALOG_PATH.relative_to(ROOT_DIR)} with {len(plugins)} plugin(s).")
        
        # Print summary of plugin versions
        for plugin in plugins:
            print(f"  - {plugin['id']}: v{plugin['version']} (updated_at: {plugin['updated_at']})")
        
        return 0
    except Exception as e:
        print(f"FATAL ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
