#!/usr/bin/env python3
"""
Script para criar uma issue no GitHub quando o catalog.toml é atualizado.
"""

import os
import sys
import tomllib
from pathlib import Path
from datetime import datetime
import subprocess
import json

ROOT_DIR = Path(__file__).resolve().parent
CATALOG_PATH = ROOT_DIR / "catalog.toml"

def get_github_token():
    token = os.environ.get('GITHUB_TOKEN')
    if not token:
        raise ValueError("GITHUB_TOKEN não encontrado")
    return token

def get_plugin_list(catalog_path: Path) -> list[dict]:
    try:
        with catalog_path.open("rb") as handle:
            data = tomllib.load(handle)
            if isinstance(data, list):
                return data
            elif "plugin" in data:
                return data["plugin"]
            return []
    except Exception as e:
        print(f"⚠️ Erro ao ler catalog.toml: {e}")
        return []

def get_previous_catalog() -> list[dict]:
    """Busca o catalog.toml do commit anterior."""
    try:
        result = subprocess.run(
            ["git", "show", "HEAD~1:catalog.toml"],
            capture_output=True,
            text=True,
            check=False
        )
        if result.returncode == 0 and result.stdout:
            try:
                data = tomllib.loads(result.stdout)
                if isinstance(data, list):
                    return data
                elif "plugin" in data:
                    return data["plugin"]
            except:
                pass
        return []
    except Exception:
        return []

def compare_plugins(current: list[dict], previous: list[dict]) -> dict:
    current_ids = {p.get('id'): p for p in current}
    previous_ids = {p.get('id'): p for p in previous}
    
    added = []
    removed = []
    updated = []
    
    for plugin_id in current_ids:
        if plugin_id not in previous_ids:
            added.append(current_ids[plugin_id])
    
    for plugin_id in previous_ids:
        if plugin_id not in current_ids:
            removed.append(previous_ids[plugin_id])
    
    for plugin_id in current_ids:
        if plugin_id in previous_ids:
            current_plugin = current_ids[plugin_id]
            previous_plugin = previous_ids[plugin_id]
            if current_plugin.get('version') != previous_plugin.get('version'):
                updated.append({
                    'id': plugin_id,
                    'name': current_plugin.get('name', plugin_id),
                    'old_version': previous_plugin.get('version', 'unknown'),
                    'new_version': current_plugin.get('version', 'unknown')
                })
    
    return {
        'added': added,
        'removed': removed,
        'updated': updated,
        'has_changes': bool(added or removed or updated)
    }

def create_issue_body(diff: dict) -> str:
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    lines = [
        f"# 🔄 Atualização do Catálogo de Plugins",
        f"",
        f"O catálogo de plugins foi atualizado em **{now}**.",
        f"",
        f"## 📊 Resumo das Mudanças",
        f"",
    ]
    
    if diff['added']:
        lines.append(f"### ✅ Plugins Adicionados ({len(diff['added'])})")
        lines.append(f"")
        for plugin in diff['added']:
            name = plugin.get('name', plugin.get('id', 'Unknown'))
            version = plugin.get('version', 'unknown')
            author = plugin.get('author', 'unknown')
            desc = plugin.get('description', '')
            lines.append(f"- **{name}** v{version} por @{author}")
            if desc:
                lines.append(f"  > {desc}")
        lines.append(f"")
    
    if diff['removed']:
        lines.append(f"### ❌ Plugins Removidos ({len(diff['removed'])})")
        lines.append(f"")
        for plugin in diff['removed']:
            name = plugin.get('name', plugin.get('id', 'Unknown'))
            version = plugin.get('version', 'unknown')
            lines.append(f"- **{name}** v{version}")
        lines.append(f"")
    
    if diff['updated']:
        lines.append(f"### 🔄 Plugins Atualizados ({len(diff['updated'])})")
        lines.append(f"")
        for plugin in diff['updated']:
            name = plugin.get('name', plugin.get('id', 'Unknown'))
            lines.append(f"- **{name}**: {plugin.get('old_version', '?')} → {plugin.get('new_version', '?')}")
        lines.append(f"")
    
    if not diff['has_changes']:
        lines.append(f"ℹ️ Nenhuma mudança detectada no catálogo de plugins.")
    
    lines.append(f"")
    lines.append(f"---")
    lines.append(f"_Esta issue foi criada automaticamente pelo GitHub Actions._")
    
    return "\n".join(lines)

def create_github_issue(repo: str, title: str, body: str, token: str):
    import requests
    
    url = f"https://api.github.com/repos/{repo}/issues"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    data = {
        "title": title,
        "body": body,
        "labels": ["automation", "catalog-update"]
    }
    
    print(f"📝 Criando issue no repositório: {repo}")
    print(f"📌 Título: {title}")
    
    response = requests.post(url, headers=headers, json=data)
    
    if response.status_code == 201:
        issue_data = response.json()
        print(f"✅ Issue criada com sucesso!")
        print(f"🔗 {issue_data.get('html_url')}")
        return True
    else:
        print(f"❌ Erro ao criar issue: {response.status_code}")
        print(f"📝 Resposta: {response.text}")
        return False

def main():
    print("🔍 Verificando mudanças no catalog.toml...")
    
    if not CATALOG_PATH.exists():
        print("❌ catalog.toml não encontrado!")
        return 1
    
    current_plugins = get_plugin_list(CATALOG_PATH)
    previous_plugins = get_previous_catalog()
    
    print(f"📊 Plugins atuais: {len(current_plugins)}")
    print(f"📊 Plugins anteriores: {len(previous_plugins)}")
    
    diff = compare_plugins(current_plugins, previous_plugins)
    
    if not diff['has_changes']:
        print("ℹ️ Nenhuma mudança detectada no catalog.toml")
        return 0
    
    print(f"📊 Mudanças detectadas:")
    print(f"  ✅ Adicionados: {len(diff['added'])}")
    print(f"  ❌ Removidos: {len(diff['removed'])}")
    print(f"  🔄 Atualizados: {len(diff['updated'])}")
    
    token = get_github_token()
    repo = os.environ.get('GITHUB_REPOSITORY', 'Nilsonlinux/noctalia-plugins')
    
    now = datetime.now().strftime('%Y-%m-%d')
    title = f"🔄 Catalog Update - {now}"
    body = create_issue_body(diff)
    
    success = create_github_issue(repo, title, body, token)
    
    return 0 if success else 1

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
