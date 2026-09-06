# noctalia-plugins
Plugins Noctalia V5 (Unofficial)

<p align="center">
  <img src="https://assets.noctalia.dev/noctalia-logo.svg?v=2](https://github.com/user-attachments/assets/b0438b6b-275c-4919-bb35-053cb96980a6" alt="Noctalia Logo" style="width: 192px" />
</p>

---
## Plugin

| Plugin | Description |
| --- | --- |
| Link/IP Monitor | `It pings a list of IPs, hosts, or links at intervals and notifies you when one goes down (or comes back up).` |
| RSS/Atom Notifier | `Monitors RSS/Atom feeds and notifies you when new items appear.` |
| Inventory Manager | `Manages product inventory with categories and low-stock alerts.` |

`https://github.com/Nilsonlinux/noctalia-plugins` 

# Noctalia Plugins

[![Atualizar Catálogo](https://github.com/Nilsonlinux/noctalia-plugins/actions/workflows/generate-catalog.yml/badge.svg)](https://github.com/Nilsonlinux/noctalia-plugins/actions/workflows/generate-catalog.yml)

Repositório de plugins para Noctalia.

## 📦 Plugins disponíveis

| Plugin | Versão | Descrição |
|--------|--------|-----------|
| Link/IP Monitor | 1.0.2 | Monitora IPs e hosts |
| RSS/Atom Notifier | 1.0.4 | Monitora feeds RSS/Atom |
| Inventory Manager | 1.0.0 | Gerencia inventário de produtos |

---
### Thumbnail

Every plugin ships a `thumbnail.webp`. It is the card image in the plugin store and on the website. Generate one with
the **[thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html)**: drop in a screenshot of
your plugin, set the title, category tag and accent color, then export the 960×540 WebP and commit it as
`<plugin>/thumbnail.webp`.

### README

`README.md` is the plugin's public page, so it must tell a user how to access every entry instead of only describing
the implementation. Follow [`README_TEMPLATE.md`](README_TEMPLATE.md), which mirrors the structure used by the
official plugins:

> ⚡ Este repositório é automatizado. O `catalog.toml` é gerado automaticamente a partir dos `plugin.toml`.
