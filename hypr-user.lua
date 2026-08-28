hl.on("hyprland.start", function()
	-- Chain commands with '&&' to enforce strict execution order:
	-- 1. Force DBus to recognize the Wayland display
	-- 2. Import variables to systemd (for Sunshine/etc.)
	-- 3. Start the graphical target
	-- 4. ONLY THEN, launch the Caelestia shell
	hl.exec_cmd(
		"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && systemctl --user start hyprland-session.target && fish -c 'cd ~/.config/quickshell/caelestia; and env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfftw3.so.3 caelestia shell -d'"
	)
end)

hl.monitor({
	output = "DP-2",
	mode = "2560x1440@240",
	position = "1920x0",
	scale = "1",
})
hl.monitor({
	output = "HDMI-A-2",
	mode = "1920x1080@60",
	position = "0x180",
	scale = "1",
})
hl.monitor({
	output = "HDMI-A-1",
	mode = "1920x1080@60",
	position = "4480x180",
	scale = "1",
})

hl.workspace_rule({ workspace = "1", monitor = "DP-2" })
hl.workspace_rule({ workspace = "2", monitor = "HDMI-A-2" })
hl.workspace_rule({ workspace = "3", monitor = "HDMI-A-1" })
