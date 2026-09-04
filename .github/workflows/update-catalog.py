#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
import tomllib
from pathlib import Path


# ===== CONFIGURAÇÃO =====
ROOT_DIR = Path(__file__).resolve().parent
CATALOG_PATH = ROOT_DIR / "catalog.toml"

REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)

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
    except (subprocess.CalledProcessError, ValueError):
        return None


def git_output(*args: str) -> str:
    try:
        return subprocess.run(
            ["git", *args], capture_output=True, text=True, check=True
        ).stdout
    except subprocess.CalledProcessError:
        return ""


def plugin_history(subdir: str) -> list[tuple[str, int, dict]]:
    history = []
    revisions = git_output(
        "log", "--format=%H %ct", "--", f"{subdir}/plugin.toml"
    ).splitlines()

    for line in revisions:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        revision = parts[0]
        commit_time = parts[1]
        
        try:
            manifest = tomllib.loads(
                git_output("show", f"{revision}:{subdir}/plugin.toml")
            )
            history.append((revision, int(commit_time), manifest))
        except (subprocess.CalledProcessError, tomllib.TOMLDecodeError, ValueError):
            continue

    return history


def release_times(history: list[tuple[str, int, dict]]) -> dict[str, int]:
    times: dict[str, int] = {}
    for _, commit_time, manifest in reversed(history):
        version = manifest.get("version")
        if isinstance(version, str) and version:
            times.setdefault(version, commit_time)
    return times


def load_plugin_manifest(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            manifest = tomllib.load(handle)
    except FileNotFoundError:
        raise ValueError(f"Arquivo não encontrado: {path}")
    except tomllib.TOMLDecodeError as e:
        raise ValueError(f"Erro ao parsear {path}: {e}")

    missing = [field for field in REQUIRED_FIELDS if field not in manifest]
    if missing:
        raise ValueError(f"{path.relative_to(ROOT_DIR)} está faltando: {', '.join(missing)}")

    plugin_api = manifest["plugin_api"]
    if not isinstance(plugin_api, int) or plugin_api <= 0:
        raise ValueError(f"{path.relative_to(ROOT_DIR)} tem plugin_api inválido")

    if not isinstance(manifest["tags"], list) or not all(
        isinstance(tag, str) for tag in manifest["tags"]
    ):
        raise ValueError(f"{path.relative_to(ROOT_DIR)} tem tags inválidas")

    out = {field: manifest[field] for field in REQUIRED_FIELDS}
    
    for field in OPTIONAL_STRING_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], str):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} tem {field} inválido")
            out[field] = manifest[field]
            
    for field in OPTIONAL_BOOL_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], bool):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} tem {field} inválido")
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
            directory = manifest_path.parent.name
            
            history = plugin_history(directory)
            released = release_times(history)
            
            if manifest["version"] in released:
                manifest["updated_at"] = released[manifest["version"]]
            
            manifest["releases"] = []
            lowest_api = manifest["plugin_api"]
            
            for revision, _, hist_manifest in history:
                if lowest_api <= OLDEST_SUPPORTED_PLUGIN_API:
                    break
                
                hist_api = hist_manifest.get("plugin_api")
                hist_version = hist_manifest.get("version")
                
                if not isinstance(hist_api, int) or not isinstance(hist_version, str):
                    continue
                if hist_api >= lowest_api or hist_api < OLDEST_SUPPORTED_PLUGIN_API:
                    continue
                
                manifest["releases"].append({
                    "plugin_api": hist_api,
                    "version": hist_version,
                    "rev": revision,
                    "updated_at": released.get(hist_version, 0),
                })
                lowest_api = hist_api
            
            plugins.append(manifest)
            print(f"✅ Plugin encontrado: {manifest['id']} (v{manifest['version']})")
            
        except Exception as e:
            print(f"⚠️  Erro ao carregar {manifest_path}: {e}")

    return plugins


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_bool(value: bool) -> str:
    return "true" if value else "false"


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
        if "deprecated" in plugin:
            lines.append(f"deprecated = {toml_bool(plugin['deprecated'])}")
            
        lines.append(f"plugin_api = {plugin['plugin_api']}")
        lines.append("tags = [" + ", ".join(toml_string(tag) for tag in plugin["tags"]) + "]")
        
        for release in plugin.get("releases", []):
            lines.extend([
                "",
                "[[plugin.release]]",
                f"plugin_api = {release['plugin_api']}",
                f"version = {toml_string(release['version'])}",
                f"updated_at = {release['updated_at']}",
                f"rev = {toml_string(release['rev'])}",
            ])

    return "\n".join(lines) + "\n"


def main() -> int:
    print(f"📂 Diretório raiz: {ROOT_DIR}")
    print(f"📄 Procurando por */plugin.toml...")
    
    plugins = discover_plugins()
    
    if not plugins:
        print("❌ Nenhum plugin encontrado!")
        return 1
    
    print(f"\n📦 Total de plugins: {len(plugins)}")
    
    # Debug: mostrar detalhes
    for p in plugins:
        print(f"  - {p['id']} (v{p['version']})")
        print(f"    updated_at: {p['updated_at']}")
        print(f"    added_at: {p['added_at']}")
    
    # Salvar catalog.toml
    CATALOG_PATH.write_text(render_catalog(plugins), encoding="utf-8")
    print(f"✅ Catalog gerado em: {CATALOG_PATH}")
    print(f"📊 Tamanho: {CATALOG_PATH.stat().st_size} bytes")
    
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"❌ Erro: {error}", file=sys.stderr)
        sys.exit(1)
