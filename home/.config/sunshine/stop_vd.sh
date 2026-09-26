#!/usr/bin/env bash
# Sunshine "Undo" command: bring the physical monitors back and drop the
# headless display.

# Forget the stream layout first, so a config reload from here on restores the
# normal monitors instead of re-applying it.
rm -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sunshine_vd.lua"
hyprctl eval "hl.monitor({ output = 'HDMI-A-1', disabled = false })"
hyprctl eval "hl.monitor({ output = 'HDMI-A-2', disabled = false })"
hyprctl eval "hl.monitor({ output = 'DP-2', disabled = false })"

# Give the monitors a moment to come back before removing the virtual one.
sleep 0.5
hyprctl output remove sunshine_vd

pkill waybar
waybar &

# Once the monitors have settled:
#  1. Re-show any workspace left with a half-finished slide animation. When
#     workspaces move back from the virtual display, one can keep a non-zero
#     draw offset, so its windows are drawn shifted sideways (hyprctl monitors
#     lists "workspace offset" under solitaryBlockedBy for that monitor).
#     Switching away and back runs the animation again from a clean start.
#  2. Rebuild Caelestia's windows: the bar and panels built while monitors come
#     back can end up stale (blurred workspaces, dead screen edges). Skipped
#     while the lock screen is up.
(
    sleep 3

    focused=$(hyprctl monitors -j | python3 -c '
import json, sys
print(next((m["name"] for m in json.load(sys.stdin) if m.get("focused")), ""))')
    hyprctl monitors -j | python3 -c '
import json, sys
for m in json.load(sys.stdin):
    if "OFFSET" in (m.get("solitaryBlockedBy") or []):
        print(m["name"], m["activeWorkspace"]["name"])' |
    while read -r mon ws; do
        hyprctl dispatch "hl.dsp.focus({ monitor = \"$mon\" })"
        hyprctl dispatch 'hl.dsp.focus({ workspace = "name:vd-reset", on_current_monitor = true })'
        sleep 0.2
        hyprctl dispatch "hl.dsp.focus({ workspace = \"$ws\", on_current_monitor = true })"
    done
    if [ -n "$focused" ]; then
        hyprctl dispatch "hl.dsp.focus({ monitor = \"$focused\" })"
    fi

    [ "$(qs -c caelestia ipc call lock isLocked 2>/dev/null)" = "true" ] && exit 0
    qs -c caelestia ipc call hypr reloadShell
) >/dev/null 2>&1 &
