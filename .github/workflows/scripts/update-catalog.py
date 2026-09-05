#!/usr/bin/env python3

import subprocess
import sys
import tomllib
from pathlib import Path
import re

ROOT_DIR = Path(__file__).resolve().parent
CATALOG_PATH = ROOT_DIR / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OLDEST_SUPPORTED_PLUGIN_API = 3

def git_commit_time(path: Path, *extra_args: str) -> int | None:
    try:
        stdout = subprocess.run(
            ["git", "log", "-1", *extra_args, "--format=%ct", "--", str(path)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        return int(stdout) if stdout else None
    except:
        return None

def load_plugin_manifest(path: Path) -> dict:
    with path.open("rb") as handle:
        manifest = tomllib.load(handle)
    
    out = {field: manifest[field] for field in REQUIRED_FIELDS}
    for field in OPTIONAL_STRING_FIELDS:
        if field in manifest:
            out[field] = manifest[field]
    
    mtime = int(path.stat().st_mtime)
    out["updated_at"] = git_commit_time(path) or mtime
    out["added_at"] = git_commit_time(path, "--diff-filter=A") or out["updated_at"]
    
    return out

def discover_plugins() -> list[dict]:
    plugins = []
    for manifest_path in sorted(ROOT_DIR.glob("*/plugin.toml")):
        try:
            manifest = load_plugin_manifest(manifest_path)
            plugins.append(manifest)
            print(f"✅ {manifest['id']} (v{manifest['version']})")
        except Exception as e:
            print(f"⚠️ Erro em {manifest_path}: {e}")
    return plugins

def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

def render_catalog(plugins: list[dict]) -> str:
    lines = [
        "# This file is auto-generated. Do not edit manually.",
        "# Noctalia plugins catalog.",
        "",
    ]
    for index, plugin in enumerate(plugins):
        if index > 0:
            lines.append("")
        lines.extend([
            "[[plugin]]",
            f"id = {toml_string(plugin['id'])}",
            f"name = {toml_string(plugin['name'])}",
            f"version = {toml_string(plugin['version'])}",
            f"updated_at = {plugin['updated_at']}",
            f"added_at = {plugin['added_at']}",
            f"author = {toml_string(plugin['author'])}",
        ])
        if "license" in plugin:
            lines.append(f"license = {toml_string(plugin['license'])}")
        if "icon" in plugin:
            lines.append(f"icon = {toml_string(plugin['icon'])}")
        if "description" in plugin:
            lines.append(f"description = {toml_string(plugin['description'])}")
        lines.append(f"plugin_api = {plugin['plugin_api']}")
        lines.append("tags = [" + ", ".join(toml_string(tag) for tag in plugin["tags"]) + "]")
    return "\n".join(lines) + "\n"

def main():
    print(f"📂 Gerando catalog.toml em: {ROOT_DIR}")
    plugins = discover_plugins()
    if not plugins:
        print("❌ Nenhum plugin encontrado!")
        return 1
    CATALOG_PATH.write_text(render_catalog(plugins), encoding="utf-8")
    print(f"✅ Catalog gerado com {len(plugins)} plugin(s)")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
