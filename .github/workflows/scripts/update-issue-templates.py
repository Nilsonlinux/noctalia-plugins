#!/usr/bin/env python3
"""
Script para atualizar templates de issues com a lista de plugins do catalog.toml
"""

import sys
import tomllib
from pathlib import Path

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
            # Se o arquivo for uma lista diretamente
            elif isinstance(data, list):
                return data
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
        print(f"ℹ️  Template bug_report.yml não encontrado, criando...")
        template_path.parent.mkdir(parents=True, exist_ok=True)
        template_path.write_text(create_bug_template(), encoding="utf-8")
        return True
    
    # Se existe, verificar se precisa atualizar
    content = template_path.read_text(encoding="utf-8")
    plugin_list = generate_plugin_list()
    
    # Atualizar a seção de plugins
    if "plugins:" in content or "### Plugins disponíveis" in content:
        new_content = update_plugin_section(content, plugin_list)
        if new_content != content:
            template_path.write_text(new_content, encoding="utf-8")
            return True
    
    return False


def update_feature_request_template() -> bool:
    """Atualiza o template de feature request com a lista de plugins."""
    template_path = ISSUE_TEMPLATE_DIR / "feature_request.yml"
    
    if not template_path.exists():
        print(f"ℹ️  Template feature_request.yml não encontrado, criando...")
        template_path.parent.mkdir(parents=True, exist_ok=True)
        template_path.write_text(create_feature_template(), encoding="utf-8")
        return True
    
    # Se existe, verificar se precisa atualizar
    content = template_path.read_text(encoding="utf-8")
    plugin_list = generate_plugin_list()
    
    # Atualizar a seção de plugins
    if "plugins:" in content or "### Plugins disponíveis" in content:
        new_content = update_plugin_section(content, plugin_list)
        if new_content != content:
            template_path.write_text(new_content, encoding="utf-8")
            return True
    
    return False


def create_bug_template() -> str:
    """Cria um template básico de bug report."""
    plugins = generate_plugin_list()
    return f"""name: Bug Report
description: Reportar um bug em um plugin
title: "[Bug]: "
labels: ["bug"]
body:
  - type: markdown
    attributes:
      value: |
        # Reportar Bug
        Obrigado por reportar um bug! Por favor, preencha as informações abaixo.

  - type: input
    id: plugin
    attributes:
      label: Plugin
      description: Qual plugin está com problema?
      placeholder: ex: link-ip-monitor
    validations:
      required: true

  - type: textarea
    id: description
    attributes:
      label: Descrição do problema
      description: Descreva o que aconteceu e o que era esperado
      placeholder: Descreva o problema aqui...
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: Passos para reproduzir
      description: Como podemos reproduzir o problema?
      placeholder: |
        1. ...
        2. ...
        3. ...
    validations:
      required: true

  - type: input
    id: version
    attributes:
      label: Versão do plugin
      placeholder: ex: 1.0.1
    validations:
      required: true

  - type: textarea
    id: logs
    attributes:
      label: Logs
      description: Cole aqui os logs relevantes
      render: shell

  - type: markdown
    attributes:
      value: |
        ## Lista de plugins disponíveis
        {plugins}
""".format(plugins=plugins)


def create_feature_template() -> str:
    """Cria um template básico de feature request."""
    plugins = generate_plugin_list()
    return f"""name: Feature Request
description: Sugerir uma nova funcionalidade
title: "[Feature]: "
labels: ["enhancement"]
body:
  - type: markdown
    attributes:
      value: |
        # Sugestão de Funcionalidade
        Obrigado por sugerir uma nova funcionalidade!

  - type: input
    id: plugin
    attributes:
      label: Plugin
      description: Para qual plugin você sugere a melhoria?
      placeholder: ex: link-ip-monitor
    validations:
      required: true

  - type: textarea
    id: feature
    attributes:
      label: Funcionalidade desejada
      description: Descreva a funcionalidade que você gostaria de ver
      placeholder: Descreva sua ideia aqui...
    validations:
      required: true

  - type: textarea
    id: motivation
    attributes:
      label: Motivação
      description: Por que essa funcionalidade seria útil?
      placeholder: Explique os benefícios...

  - type: markdown
    attributes:
      value: |
        ## Lista de plugins disponíveis
        {plugins}
""".format(plugins=plugins)


def update_plugin_section(content: str, plugin_list: str) -> str:
    """Atualiza a seção de plugins em um template."""
    import re
    
    # Procurar por padrões de seção de plugins
    patterns = [
        r'(#+\s*Lista de plugins disponíveis\n\n).*?(?=\n\n|$)',
        r'(### Plugins disponíveis\n\n).*?(?=\n\n|$)',
        r'(plugins:\n\n).*?(?=\n\n|$)',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, content, re.DOTALL)
        if match:
            replacement = match.group(1) + plugin_list
            return content.replace(match.group(0), replacement)
    
    # Se não encontrou, adicionar ao final
    return content + f"\n\n## Lista de plugins disponíveis\n\n{plugin_list}"


def main() -> int:
    """Função principal."""
    print("🔄 Atualizando templates de issues...")
    
    # Criar diretório se não existir
    ISSUE_TEMPLATE_DIR.mkdir(parents=True, exist_ok=True)
    
    try:
        bug_updated = update_bug_report_template()
        feature_updated = update_feature_request_template()
        
        if bug_updated:
            print("✅ Template de bug report atualizado")
        else:
            print("ℹ️ Template de bug report já está atualizado")
        
        if feature_updated:
            print("✅ Template de feature request atualizado")
        else:
            print("ℹ️ Template de feature request já está atualizado")
        
        return 0
        
    except Exception as e:
        print(f"❌ Erro ao atualizar templates: {e}")
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
