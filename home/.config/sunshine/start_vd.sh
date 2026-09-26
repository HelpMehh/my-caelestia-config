#!/usr/bin/env bash
# Sunshine "Do" command: swap the physical monitors for a headless display
# sized to the client.
#
# The layout is written to a state file as well as applied. Any Hyprland
# config reload (a wallpaper change reloads it, because Caelestia rewrites
# ~/.config/hypr/scheme/current.lua) wipes runtime monitor rules, so
# hypr-user.lua re-applies this file on every reload. stop_vd.sh deletes it.

wide=0
if [ $wide -eq 1 ]; then
    WIDTH=2560; HEIGHT=1072; FPS=30
else
    WIDTH=$SUNSHINE_CLIENT_WIDTH; HEIGHT=$SUNSHINE_CLIENT_HEIGHT; FPS=${SUNSHINE_CLIENT_FPS:-60}
fi

# These come from the streaming client and end up in Lua that Hyprland runs,
# so accept plain numbers only.
for v in "$WIDTH" "$HEIGHT" "$FPS"; do
    case "$v" in
        ''|*[!0-9]*) echo "start_vd.sh: bad client mode '${WIDTH}x${HEIGHT}@${FPS}'" >&2; exit 1 ;;
    esac
done

STATE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sunshine_vd.lua"

cat > "$STATE" <<EOF
hl.monitor({ output = "sunshine_vd", mode = "${WIDTH}x${HEIGHT}@${FPS}", position = "auto", scale = 1 })
hl.monitor({ output = "HDMI-A-1", disabled = true })
hl.monitor({ output = "HDMI-A-2", disabled = true })
hl.monitor({ output = "DP-2", disabled = true })
EOF

hyprctl output create headless sunshine_vd
hyprctl eval "dofile('$STATE')"

sleep 0.2
pkill waybar
waybar &
