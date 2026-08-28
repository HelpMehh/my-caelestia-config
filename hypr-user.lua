hl.exec_once(
	"systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && systemctl --user start hyprland-session.target"
)
