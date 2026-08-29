#!/usr/bin/env bash

# Wait for Hyprland's IPC socket to exist before touching hyprctl or exporting
# HYPRLAND_INSTANCE_SIGNATURE.
while ! hyprctl instances >/dev/null 2>&1; do sleep 0.1; done

# Export Wayland/Hyprland variables into the DBus and systemd user environments.
# This MUST happen before hyprland-session.target starts — services pulled in by
# graphical-session.target (Sunshine, screen capture) inherit the environment as
# it exists at their start, and will come up blind without these.
dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE
systemctl --user import-environment \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE

# Bind graphical-session.target so WantedBy=graphical-session.target units start.
# --no-block so a slow unit (Sunshine waiting on the GPU, say) can't hold up the shell.
systemctl --user start --no-block hyprland-session.target

# Launch Caelestia. LD_PRELOAD works around a link-order issue in the local
# libcaelestia build; see note in hypr-setup.sh.
cd ~/.config/quickshell/caelestia || exit 1
exec env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfftw3.so.3 caelestia shell -d
