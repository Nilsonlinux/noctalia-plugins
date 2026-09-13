#!/usr/bin/env bash
# edit_contacts.sh add <name> <path> | del <name> | set <old-name> <new-name> <new-path>
# Adds, removes or renames one entry in the plugin's "contacts" string_map inside
# Noctalia's app-managed settings.toml (the same file the Settings window writes).
# The file is created when missing, merged into the existing "contacts" table
# (never leaving a duplicate declaration), validated with tomllib both before
# and after editing, and only then written. An unparseable file is backed up and
# left untouched. Invoked by the plugin's panel; the caller runs
# `noctalia msg config-reload` after.
set -eu

MODE="${1:-}"
NAME="${2:-}"
PATH_VALUE="${3:-}"
PATH_VALUE2="${4:-}"

case "$MODE" in
  add)
    if [ -z "$NAME" ] || [ -z "$PATH_VALUE" ]; then
      echo "usage: edit_contacts.sh add <name> <path>" >&2
      exit 1
    fi
    ;;
  del)
    if [ -z "$NAME" ]; then
      echo "usage: edit_contacts.sh del <name>" >&2
      exit 1
    fi
    ;;
  set)
    if [ -z "$NAME" ] || [ -z "$PATH_VALUE" ] || [ -z "$PATH_VALUE2" ]; then
      echo "usage: edit_contacts.sh set <old-name> <new-name> <new-path>" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: edit_contacts.sh add <name> <path> | del <name> | set <old-name> <new-name> <new-path>" >&2
    exit 1
    ;;
esac

STATE_DIR="${NOCTALIA_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}}/noctalia"
FILE="$STATE_DIR/settings.toml"
mkdir -p "$STATE_DIR"
if [ ! -f "$FILE" ]; then
  printf '[plugin_settings."nilsonlinux/contact-sounds".contacts]\n' > "$FILE"
fi

export MODE NAME PATH_VALUE PATH_VALUE2
python3 - "$FILE" <<'PY'
import os, sys, tomllib, time, shutil

MODE = os.environ["MODE"]
NAME = os.environ["NAME"]
PATH_VALUE = os.environ.get("PATH_VALUE", "")
PATH_VALUE2 = os.environ.get("PATH_VALUE2", "")
FILE = sys.argv[1]

PLUGIN = "nilsonlinux/contact-sounds"
PARENT = '[plugin_settings."%s"]' % PLUGIN
SECTION = '[plugin_settings."%s".contacts]' % PLUGIN


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def key_of(line):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None
    k = s.split("=", 1)[0].strip()
    if k.startswith('"') and k.endswith('"'):
        return k[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return k


def section_bounds(lines, target):
    idx = None
    for i, line in enumerate(lines):
        if line.strip() == target:
            idx = i
            break
    if idx is None:
        return None, None
    end = len(lines)
    for i in range(idx + 1, len(lines)):
        if lines[i].strip().startswith("["):
            end = i
            break
    return idx, end


def indent_of(line):
    return line[: len(line) - len(line.lstrip())]


def entry_line(indent, key, value):
    return indent + q(key) + " = " + q(value)


def inline_table(items):
    return "{ " + ", ".join(q(k) + " = " + q(v) for k, v in items) + " }"


# --- read and validate the current content; never edit a broken file ------
with open(FILE, "rb") as fh:
    try:
        data = tomllib.load(fh)
    except tomllib.TOMLDecodeError as err:
        backup = FILE + ".broken-" + time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(FILE, backup)
        print("settings.toml is not valid TOML (%s); backup saved to %s; nothing changed"
              % (err, backup), file=sys.stderr)
        sys.exit(1)

cfg = data.get("plugin_settings", {}).get(PLUGIN)
base = {}
if isinstance(cfg, dict) and isinstance(cfg.get("contacts"), dict):
    base = dict(cfg["contacts"])

if MODE == "del":
    base.pop(NAME, None)
elif MODE == "set":
    base.pop(NAME, None)
    base[PATH_VALUE] = PATH_VALUE2
else:
    base[NAME] = PATH_VALUE

with open(FILE, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

p_start, p_end = section_bounds(lines, PARENT)
s_start, s_end = section_bounds(lines, SECTION)

inline_idx = None
if p_start is not None:
    for j in range(p_start + 1, p_end):
        if s_start is not None and s_start <= j < s_end:
            continue
        if key_of(lines[j]) == "contacts":
            inline_idx = j
            break

if MODE == "del" and p_start is None and s_start is None and inline_idx is None:
    sys.exit(0)

if s_start is not None:
    indent = ""
    for j in range(s_start + 1, s_end):
        if key_of(lines[j]) is not None:
            indent = indent_of(lines[j])
            break
    out = lines[:s_start + 1]
    for k, v in sorted(base.items()):
        out.append(entry_line(indent, k, v))
    out += lines[s_end:]
elif inline_idx is not None:
    out = list(lines)
    out[inline_idx] = indent_of(lines[inline_idx]) + "contacts = " + inline_table(base.items())
elif p_start is not None:
    block = ["    " + SECTION]
    for k, v in sorted(base.items()):
        block.append("        " + q(k) + " = " + q(v))
    block.append("")
    out = lines[:p_end] + block + lines[p_end:]
else:
    out = lines[:]
    if out and out[-1].strip():
        out.append("")
    out.append(PARENT)
    out.append("    " + SECTION)
    for k, v in sorted(base.items()):
        out.append("        " + q(k) + " = " + q(v))

candidate = "\n".join(out) + "\n"
try:
    tomllib.loads(candidate)
except tomllib.TOMLDecodeError as err:
    print("refusing to write invalid settings.toml (%s); nothing changed" % err, file=sys.stderr)
    sys.exit(1)

with open(FILE, "w", encoding="utf-8") as fh:
    fh.write(candidate)
PY