# Noctalia plugins
Plugins Noctalia V5 (Unofficial)

<p align="center">
  <img src="https://assets.noctalia.dev/noctalia-logo.svg?v=2](https://github.com/user-attachments/assets/b0438b6b-275c-4919-bb35-053cb96980a6" alt="Noctalia Logo" style="width: 192px" />
</p>

---
## Plugins

| Plugin | Description |
| --- | --- |
| Link/IP Monitor | `It pings a list of IPs, hosts, or links at intervals and notifies you when one goes down (or comes back up).` |
| RSS/Atom Notifier | `Monitors RSS/Atom feeds and notifies you when new items appear.` |
| Inventory Manager | `Inventory Manager for managing product inventory with categories, low stock alerts, and data export.` |
| Speedtest Meter | `Run an internet speed test with a live speedometer and detailed results.` |
| Contact Notification Sounds | `Plays a unique sound (OGG/MP3) for notifications from people in your contact list.` |
| World Radio | `Browse thousands of radio stations from around the world with country flags.` |

`https://github.com/Nilsonlinux/noctalia-plugins` 

# Noctalia Plugins

[![Atualizar Catálogo](https://github.com/Nilsonlinux/noctalia-plugins/actions/workflows/generate-catalog.yml/badge.svg)](https://github.com/Nilsonlinux/noctalia-plugins/actions/workflows/generate-catalog.yml)

Repositório de plugins para Noctalia.

---
### Thumbnail

Every plugin ships a `thumbnail.webp`. It is the card image in the plugin store and on the website. Generate one with
the **[thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html)**: drop in a screenshot of
your plugin, set the title, category tag and accent color, then export the 960×540 WebP and commit it as
`<plugin>/thumbnail.webp`.

### Translations

> [!WARNING]
> **Editing existing translations must be done on [Noctalia Translate](https://i18n.noctalia.dev)**, the single
> source of truth for all translated strings. Do not edit the strings of an existing translation in the locale JSON
> files here: they will most likely be overwritten on the next i18n pull.

Write `translations/en.json` only. Every `label_key` and `description_key` in `plugin.toml` must resolve to a key in
it, and CI checks this. Do not add machine-translated locales; other languages are handled separately.

The plugins here are also published in the community catalog, so their strings are translated in the shared
`community-plugins` project. To sync the latest translated locales in a working checkout, run:

```sh
./.tools/i18n-pull.sh
```

The command asks for confirmation and overwrites the non-English locale files returned by the translation service.
`translations/en.json` is the authoritative source in this repository and is never overwritten here. The command does
not delete local locale files that are absent from the export, and it skips plugins the translation service knows
about that this repository does not ship. Review the resulting diff before committing anything.

### Tags

The `tags` in `plugin.toml` are used for catalog search. Tags must be lowercase and selected from this list:

- Surfaces: `bar`, `desktop`, `launcher`, `panel`, `service`, `shortcut`
- Purpose: `ai`, `animation`, `audio`, `clock`, `countdown`, `demo`, `development`, `emoticon`, `fun`, `gaming`,
  `hardware`, `indicator`, `language`, `media`, `music`, `network`, `privacy`, `productivity`, `recording`, `system`,
  `theming`, `time`, `utility`, `video`, `wallpaper`
- Compositors: `hyprland`, `labwc`, `mangowc`, `niri`, `sway`
- Distributions: `arch`, `debian`, `fedora`, `gentoo`, `nixos`, `opensuse`, `void`

> ⚡ Este repositório é automatizado. O `catalog.toml` é gerado automaticamente a partir dos `plugin.toml`.
