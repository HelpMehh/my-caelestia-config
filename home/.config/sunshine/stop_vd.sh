#!/usr/bin/env bash

# 1. Wake the physical monitor up via power-state toggle first (Change 'DP-1' to your screen)
rm -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sunshine_vd.lua"
hyprctl eval "hl.monitor({ output = 'HDMI-A-1', disabled = false })"
hyprctl eval "hl.monitor({ output = 'HDMI-A-2', disabled = false })"
hyprctl eval "hl.monitor({ output = 'DP-2', disabled = false })"
# 2. Give the display system a split second to re-engage the hardware panel
sleep 0.5

# 3. Safely remove our custom-named virtual display
hyprctl output remove sunshine_vd

pkill waybar
waybar &
