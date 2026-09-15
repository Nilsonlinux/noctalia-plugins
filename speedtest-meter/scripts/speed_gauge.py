#!/usr/bin/env python3
# Live speedometer worker for the Speedtest Meter panel.
#
# The Lua panel writes its live download/upload values to a small JSON file
# (first CLI arg). This worker polls that file and, whenever the values
# change, redraws the two speedometer dials (download/upload) with Pillow
# using draw_graph.draw_speedometer() — the same ring-arc rendering core used
# by the "processes" plugin. It reports every freshly written image to the
# panel over stdout so it can refresh the ui.image controls.
#
# Args: <live_json_path> <download_png_path> <upload_png_path> <skin>

import atexit
import json
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from draw_graph import draw_speedometer  # noqa: E402

LIVE_FILE = sys.argv[1] if len(sys.argv) > 1 else None
DOWN_FILE = sys.argv[2] if len(sys.argv) > 2 else None
UP_FILE = sys.argv[3] if len(sys.argv) > 3 else None
SKIN = sys.argv[4] if len(sys.argv) > 4 else "dark"

PID = os.getpid()
FILES = [p for p in (LIVE_FILE, DOWN_FILE, UP_FILE) if p]


def cleanup():
    """Remove every generated/runtime file when the worker is stopped."""
    for path in FILES:
        try:
            if path and os.path.exists(path):
                os.remove(path)
        except OSError:
            pass


atexit.register(cleanup)


def handle_signal(signum, frame):
    raise SystemExit(0)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def parse_accent(text, default):
    try:
        parts = [int(x.strip()) for x in str(text).split(",")]
        if len(parts) == 3 and all(0 <= v <= 255 for v in parts):
            return tuple(parts)
    except (ValueError, TypeError):
        pass
    return default


def make_state(data):
    """A cheap immutable hash of the current live values, to detect changes."""
    if not data:
        return None
    d = data.get("download") or {}
    u = data.get("upload") or {}
    state = []
    for g in (d, u):
        state.append(round(float(g.get("percent") or 0), 1))
        state.append(str(g.get("value_text") or ""))
        state.append(str(g.get("unit") or ""))
        state.append(str(g.get("label") or ""))
        state.append(str(g.get("accent") or ""))
    state.append(str(data.get("max_label") or ""))
    return tuple(state)


def main():
    if not (LIVE_FILE and DOWN_FILE and UP_FILE):
        return

    print("speedtest-gauge:pid:%d" % PID, flush=True)

    last_state = None
    while True:
        data = None
        try:
            with open(LIVE_FILE, "r") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = None

        state = make_state(data)
        if state is not None and state != last_state:
            last_state = state
            d = data.get("download") or {}
            u = data.get("upload") or {}
            down_accent = parse_accent(d.get("accent"), (120, 180, 255))
            up_accent = parse_accent(u.get("accent"), (255, 185, 120))
            max_label = str(data.get("max_label") or "")
            try:
                draw_speedometer(
                    percent=float(d.get("percent") or 0),
                    value_text=str(d.get("value_text") or "0"),
                    unit_text=str(d.get("unit") or ""),
                    label_text=str(d.get("label") or ""),
                    max_label=max_label,
                    accent=down_accent,
                    skin_name=SKIN,
                    filename=DOWN_FILE,
                )
                draw_speedometer(
                    percent=float(u.get("percent") or 0),
                    value_text=str(u.get("value_text") or "0"),
                    unit_text=str(u.get("unit") or ""),
                    label_text=str(u.get("label") or ""),
                    max_label=max_label,
                    accent=up_accent,
                    skin_name=SKIN,
                    filename=UP_FILE,
                )
                print("speedtest-gauge:ready:%s" % DOWN_FILE, flush=True)
                print("speedtest-gauge:ready:%s" % UP_FILE, flush=True)
            except Exception as exc:  # keep looping; panel keeps its fallback
                sys.stderr.write("speedtest-gauge:error:%s\n" % exc)
        time.sleep(0.15)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, SystemExit):
        pass
    except Exception as exc:
        sys.stderr.write("speedtest-gauge:fatal:%s\n" % exc)
        sys.exit(1)