#!/usr/bin/env python3
"""
Script para criar uma issue no GitHub quando o catalog.toml é atualizado.
"""

import os
import json
import sys
import tomllib
from pathlib import Path
from datetime import datetime
import subprocess

ROOT_DIR = Path(__file__).resolve().parents[3]
CATALOG_PATH = ROOT_DIR / "catalog.toml"

def get_github_token():
    """Obtém o token do GitHub das variáveis de ambiente."""
    token = os.environ.get('GITHUB_TOKEN')
    if not token:
        raise ValueError("GITHUB_TOKEN não encontrado nas variáveis de ambiente")
    return token

def get_plugin_list(catalog_path: Path) -> list[dict]:
    """Lê o catalog.toml e retorna a lista de plugins."""
    try:
        with catalog_path.open("rb") as handle:
            data = tomllib.load(handle)
            if isinstance(data, list):
                return data
            elif "plugin" in data:
                return data["plugin"]
            return []
    except FileNotFoundError:
        return []

def get_previous_catalog() -> list[dict]:
    """Busca o catalog.toml do commit anterior."""
    try:
        # Buscar o conteúdo do catalog.toml do commit anterior
        result = subprocess.run(
            ["git", "show", "HEAD~1:catalog.toml"],
            capture_output=True,
            text=True,
            check=False
        )
        if result.returncode == 0 and result.stdout:
            # Parsear o TOML do commit anterior
            import tomllib
            data = tomllib.loads(result.stdout)
            if isinstance(data, list):
                return data
            elif "plugin" in data:
                return data["plugin"]
        return []
    except Exception:
        return []

def compare_plugins(current: list[dict], previous: list[dict]) -> dict:
    """Compara duas listas de plugins e retorna as diferenças."""
    current_ids = {p.get('id'): p for p in current}
    previous_ids = {p.get('id'): p for p in previous}
    
    added = []
    removed = []
    updated = []
    
    # Plugins adicionados
    for plugin_id in current_ids:
        if plugin_id not in previous_ids:
            added.append(current_ids[plugin_id])
    
    # Plugins removidos
    for plugin_id in previous_ids:
        if plugin_id not in current_ids:
            removed.append(previous_ids[plugin_id])
    
    # Plugins atualizados (mesmo id, versão diferente)
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
    """Cria o corpo da issue com as mudanças."""
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    lines = [
        f"# 🔄 Atualização do Catálogo de Plugins",
        f"",
        f"O catálogo de plugins foi atualizado em **{now}**.",
        f"",
        f"## 📊 Resumo das Mudanças",
        f"",
    ]
    
    # Plugins adicionados
    if diff['added']:
        lines.append(f"### ✅ Plugins Adicionados ({len(diff['added'])})")
        lines.append(f"")
        for plugin in diff['added']:
            name = plugin.get('name', plugin.get('id', 'Unknown'))
            version = plugin.get('version', 'unknown')
            author = plugin.get('author', 'unknown')
            lines.append(f"- **{name}** v{version} por @{author}")
            if plugin.get('description'):
                lines.append(f"  > {plugin.get('description')}")
        lines.append(f"")
    
    # Plugins removidos
    if diff['removed']:
        lines.append(f"### ❌ Plugins Removidos ({len(diff['removed'])})")
        lines.append(f"")
        for plugin in diff['removed']:
            name = plugin.get('name', plugin.get('id', 'Unknown'))
            version = plugin.get('version', 'unknown')
            lines.append(f"- **{name}** v{version}")
        lines.append(f"")
    
    # Plugins atualizados
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
    """Cria uma issue no GitHub usando a API."""
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
    
    response = requests.post(url, headers=headers, json=data)
    
    if response.status_code == 201:
        print(f"✅ Issue criada com sucesso!")
        issue_url = response.json().get('html_url')
        print(f"🔗 {issue_url}")
        return True
    else:
        print(f"❌ Erro ao criar issue: {response.status_code}")
        print(f"📝 Resposta: {response.text}")
        return False

def main():
    """Função principal."""
    print("🔍 Verificando mudanças no catalog.toml...")
    
    # Verificar se o catalog.toml existe
    if not CATALOG_PATH.exists():
        print("❌ catalog.toml não encontrado!")
        return 1
    
    # Carregar catalog atual
    current_plugins = get_plugin_list(CATALOG_PATH)
    
    # Carregar catalog anterior
    previous_plugins = get_previous_catalog()
    
    # Comparar
    diff = compare_plugins(current_plugins, previous_plugins)
    
    if not diff['has_changes']:
        print("ℹ️ Nenhuma mudança detectada no catalog.toml")
        return 0
    
    print(f"📊 Mudanças detectadas:")
    print(f"  ✅ Adicionados: {len(diff['added'])}")
    print(f"  ❌ Removidos: {len(diff['removed'])}")
    print(f"  🔄 Atualizados: {len(diff['updated'])}")
    
    # Criar issue
    token = get_github_token()
    repo = os.environ.get('GITHUB_REPOSITORY', 'Nilsonlinux/noctalia-plugins')
    
    # Título da issue
    now = datetime.now().strftime('%Y-%m-%d')
    title = f"🔄 Catalog Update - {now}"
    
    # Corpo da issue
    body = create_issue_body(diff)
    
    print(f"📝 Criando issue...")
    success = create_github_issue(repo, title, body, token)
    
    return 0 if success else 1

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
