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

# Rebuild Caelestia's windows once the monitors have settled. The bar and
# panels built while monitors come back can end up stale (blurred workspaces,
# dead screen edges on DP-2), and a reload fixes that. Skipped while the lock
# screen is up.
(
    sleep 3
    [ "$(qs -c caelestia ipc call lock isLocked 2>/dev/null)" = "true" ] && exit 0
    qs -c caelestia ipc call hypr reloadShell
) >/dev/null 2>&1 &
