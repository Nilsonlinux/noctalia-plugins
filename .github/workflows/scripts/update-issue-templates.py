#!/usr/bin/env python3

import os
import sys
from pathlib import Path
import tomllib

ROOT_DIR = Path(__file__).resolve().parents[3]
ISSUE_TEMPLATE_DIR = ROOT_DIR / ".github" / "ISSUE_TEMPLATE"
CATALOG_PATH = ROOT_DIR / "catalog.toml"

def load_catalog() -> list[dict]:
    """Carrega o catalog.toml e retorna a lista de plugins."""
    try:
        with CATALOG_PATH.open("rb") as handle:
            data = tomllib.load(handle)
            # Se for uma lista de plugins
            if "plugin" in data:
                return data["plugin"]
            return []
    except FileNotFoundError:
        print("❌ catalog.toml não encontrado!")
        return []
    except tomllib.TOMLDecodeError as e:
        print(f"❌ Erro ao parsear catalog.toml: {e}")
        return []

def generate_plugin_list() -> str:
    """Gera uma lista formatada de plugins para os templates."""
    plugins = load_catalog()
    if not plugins:
        return "Nenhum plugin disponível."

    lines = ["### Plugins disponíveis:", ""]
    for plugin in plugins:
        name = plugin.get("name", "Sem nome")
        plugin_id = plugin.get("id", "Sem ID")
        description = plugin.get("description", "Sem descrição")
        lines.append(f"- **{name}** (`{plugin_id}`)")
        lines.append(f"  {description}")
        lines.append("")
    
    return "\n".join(lines)

def update_bug_report_template() -> bool:
    """Atualiza o template de bug report com a lista de plugins."""
    template_path = ISSUE_TEMPLATE_DIR / "bug_report.yml"
    
    if not template_path.exists():
        print(f"⚠️  Template não encontrado: {template_path}")
        return False
    
    content = template_path.read_text(encoding="utf-8")
    
    # Procurar a seção onde a lista de plugins deve ser inserida
    plugin_list = generate_plugin_list()
    
    # Marcação para substituir
    marker_start = "# PLUGIN_LIST_START"
    marker_end = "# PLUGIN_LIST_END"
    
    if marker_start in content and marker_end in content:
        # Substituir a seção entre os marcadores
        pattern = f"{marker_start}.*?{marker_end}"
        replacement = f"{marker_start}\n{plugin_list}\n{marker_end}"
        new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)
    else:
        # Se não houver marcadores, adicionar ao final
        new_content = content + f"\n\n# Plugin List\n{plugin_list}"
    
    if new_content != content:
        template_path.write_text(new_content, encoding="utf-8")
        return True
    
    return False

def update_feature_request_template() -> bool:
    """Atualiza o template de feature request com a lista de plugins."""
    template_path = ISSUE_TEMPLATE_DIR / "feature_request.yml"
    
    if not template_path.exists():
        print(f"⚠️  Template não encontrado: {template_path}")
        return False
    
    content = template_path.read_text(encoding="utf-8")
    
    # Similar ao bug report
    plugin_list = generate_plugin_list()
    
    marker_start = "# PLUGIN_LIST_START"
    marker_end = "# PLUGIN_LIST_END"
    
    if marker_start in content and marker_end in content:
        pattern = f"{marker_start}.*?{marker_end}"
        replacement = f"{marker_start}\n{plugin_list}\n{marker_end}"
        new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)
    else:
        new_content = content + f"\n\n# Plugin List\n{plugin_list}"
    
    if new_content != content:
        template_path.write_text(new_content, encoding="utf-8")
        return True
    
    return False

def main() -> int:
    print("🔄 Atualizando templates de issues...")
    
    # Criar diretório se não existir
    ISSUE_TEMPLATE_DIR.mkdir(parents=True, exist_ok=True)
    
    bug_updated = update_bug_report_template()
    feature_updated = update_feature_request_template()
    
    if bug_updated:
        print("✅ Template de bug report atualizado")
    else:
        print("ℹ️ Template de bug report não precisou ser atualizado")
    
    if feature_updated:
        print("✅ Template de feature request atualizado")
    else:
        print("ℹ️ Template de feature request não precisou ser atualizado")
    
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
