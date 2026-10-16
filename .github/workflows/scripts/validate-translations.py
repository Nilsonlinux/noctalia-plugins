#!/usr/bin/env python3

"""Validate that plugin manifests and translations/en.json agree.

This mirrors the translation rules enforced by the community catalog's
`validate-plugins.py`, without pulling in the full manifest/entry/thumbnail
validator:

- every plugin ships `translations/en.json`, a JSON object;
- each object key in `translations/en.json` is a single lowercase segment
  (`a-z`, `0-9`, dashes and non-leading underscores) and contains no dot;
- every `label_key` and `description_key` in `plugin.toml` - including setting
  options and nested entry settings - is a valid lowercase dotted key path and
  resolves to a key in that plugin's `translations/en.json`.

Run from the repository root:

    python3 .github/workflows/scripts/validate-translations.py
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]

# An id segment must be a lowercase flat identifier: the part after the "/" is also the
# plugin's directory here, its export directory on disk, and its slug on the website.
ID_SEGMENT_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

# The store flattens every plugin's translations under its id and rejects keys that are not
# lowercase. A dotted label_key is a path of segments; each segment allows a-z, 0-9, dashes,
# and underscores, but an underscore may not lead a segment.
TRANSLATION_KEY_SEGMENT_RE = re.compile(r"[a-z0-9-][a-z0-9_-]*")
TRANSLATION_KEY_RULE = (
    "keys must be lowercase and contain only a-z, 0-9, dots, dashes, and non-leading underscores"
)
# Rule for a single object key inside translations/en.json. The dot is a path separator, so it
# cannot appear inside a key: the i18n platform expands "a.b" into nested objects on the next
# sync, and a flat dotted key would silently churn. Nest with objects instead.
TRANSLATION_SEGMENT_RULE = (
    "each translations/en.json key must be a single lowercase segment (a-z, 0-9, dashes, "
    "non-leading underscores) with no dots; express nesting with objects, not dotted keys"
)

TRANSLATION_KEY_FIELDS = ("label_key", "description_key")


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def is_valid_key_segment(segment: str) -> bool:
    """True if a single translation key segment is lowercase and dot-free."""
    return TRANSLATION_KEY_SEGMENT_RE.fullmatch(segment) is not None


def is_valid_translation_key(key: str) -> bool:
    """True if a dotted label_key path obeys the store's lowercase key rule."""
    return all(is_valid_key_segment(part) for part in key.split("."))


def invalid_translation_keys(node: Any, prefix: str = "") -> list[str]:
    """Return dotted paths in a translations tree whose own object key breaks the segment rule."""
    invalid: list[str] = []
    if not isinstance(node, dict):
        return invalid
    for key, value in node.items():
        path = f"{prefix}.{key}" if prefix else key
        if not isinstance(key, str) or not is_valid_key_segment(key):
            invalid.append(path)
        invalid.extend(invalid_translation_keys(value, path))
    return invalid


def has_key_path(data: Any, dotted_key: str) -> bool:
    if isinstance(data, dict) and dotted_key in data:
        return True

    current = data
    for part in dotted_key.split("."):
        if not isinstance(current, dict) or part not in current:
            return False
        current = current[part]
    return True


class Validator:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def add_error(self, path: Path, message: str) -> None:
        self.errors.append(f"{rel(path)}: {message}")

    def load_manifest(self, path: Path) -> dict[str, Any] | None:
        try:
            with path.open("rb") as handle:
                manifest = tomllib.load(handle)
        except tomllib.TOMLDecodeError as error:
            self.add_error(path, f"invalid TOML: {error}")
            return None

        if not isinstance(manifest, dict):
            self.add_error(path, "expected a TOML table")
            return None
        return manifest

    def load_english_translations(self, plugin_dir: Path) -> Any | None:
        path = plugin_dir / "translations" / "en.json"
        if not path.exists():
            self.add_error(path, "missing required translations/en.json")
            return None

        try:
            with path.open("r", encoding="utf-8") as handle:
                translations = json.load(handle)
        except json.JSONDecodeError as error:
            self.add_error(path, f"invalid JSON: {error}")
            return None

        if not isinstance(translations, dict):
            self.add_error(path, "expected a JSON object")
            return None
        return translations

    def validate_translation_key(
        self,
        manifest_path: Path,
        translations: Any | None,
        context: str,
        field: str,
        value: Any,
    ) -> None:
        if not isinstance(value, str) or value.strip() == "":
            self.add_error(manifest_path, f"{context}: {field} must be a non-empty string")
            return

        if not is_valid_translation_key(value):
            self.add_error(
                manifest_path,
                f"{context}: {field} '{value}' is not a valid translation key: {TRANSLATION_KEY_RULE}",
            )
            return

        if translations is None:
            self.add_error(
                manifest_path,
                f"{context}: {field} references '{value}', but translations/en.json is missing or invalid",
            )
            return

        if not has_key_path(translations, value):
            self.add_error(
                manifest_path,
                f"{context}: {field} references missing translations/en.json key '{value}'",
            )

    def validate_plugin(self, manifest_path: Path) -> None:
        plugin_dir = manifest_path.parent
        folder = plugin_dir.name
        if not ID_SEGMENT_RE.fullmatch(folder):
            self.add_error(
                manifest_path,
                f"plugin directory '{folder}' must be lowercase and match {ID_SEGMENT_RE.pattern}",
            )

        manifest = self.load_manifest(manifest_path)
        if manifest is None:
            return

        translations = self.load_english_translations(plugin_dir)
        if translations is not None:
            invalid = invalid_translation_keys(translations)
            if invalid:
                self.add_error(
                    plugin_dir / "translations" / "en.json",
                    f"invalid translation key format: {', '.join(invalid)}; {TRANSLATION_SEGMENT_RULE}",
                )

        for context, field, value in find_keys(manifest):
            self.validate_translation_key(manifest_path, translations, context, field, value)


def find_keys(node: Any, context: str = "") -> list[tuple[str, str, Any]]:
    """Return (context, field, value) for every label_key/description_key in a manifest."""
    found: list[tuple[str, str, Any]] = []
    if isinstance(node, dict):
        for field in TRANSLATION_KEY_FIELDS:
            if field in node:
                found.append((context or "root", field, node[field]))
        for key, value in node.items():
            child_context = f"{context}.{key}" if context else str(key)
            found.extend(find_keys(value, child_context))
    elif isinstance(node, list):
        for index, item in enumerate(node):
            found.extend(find_keys(item, f"{context}[{index}]"))
    return found


def main() -> int:
    manifests = sorted(ROOT.glob("*/plugin.toml"))
    if not manifests:
        print(f"Error: no plugin manifests found in {ROOT}", file=sys.stderr)
        return 1

    validator = Validator()
    for manifest_path in manifests:
        validator.validate_plugin(manifest_path)

    if validator.errors:
        for error in validator.errors:
            print(f"error: {error}", file=sys.stderr)
        print(f"\n{len(validator.errors)} translation error(s) found.", file=sys.stderr)
        return 1

    print(f"Validated translations for {len(manifests)} plugin(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
