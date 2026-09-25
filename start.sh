#!/usr/bin/env bash
while ! hyprctl instances >/dev/null 2>&1; do sleep 0.1; done

dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE
systemctl --user import-environment \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE

systemctl --user start --no-block hyprland-session.target

thunar --daemon &

cd ~/.config/quickshell/caelestia || exit 1
env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfftw3.so.3 caelestia shell -d
qs -c caelestia ipc call lock lock
sleep 1
while [ "$(qs -c caelestia ipc call lock isLocked)" = "true" ]; do sleep 1; done
caelestia wallpaper -r
