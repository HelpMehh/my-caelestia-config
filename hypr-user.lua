hl.on("hyprland.start", function()
	hl.exec_cmd(
		"dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && systemctl --user start hyprland-session.target"
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

hl.device({
	name = "libvirtualhid-keyboard",
	repeat_delay = 1000,
})

hl.workspace_rule({ workspace = "1", monitor = "DP-2" })
hl.workspace_rule({ workspace = "2", monitor = "HDMI-A-2" })
hl.workspace_rule({ workspace = "3", monitor = "HDMI-A-1" })

do
	local state = (os.getenv("XDG_RUNTIME_DIR") or "") .. "/sunshine_vd.lua"
	local f = io.open(state, "r")
	if f then
		f:close()
		local ok, vd = pcall(hl.get_monitor, "sunshine_vd")
		if not ok or vd then
			pcall(dofile, state)
		end
	end
end
