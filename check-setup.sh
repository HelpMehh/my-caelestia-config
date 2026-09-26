#!/usr/bin/env bash
# Checks that today's changes are committed, pushed, installed and patched in.
# Read-only: it changes nothing. Run from a terminal inside Hyprland:
#     bash ~/Downloads/check-setup.sh

REPO="https://github.com/HelpMehh/my-caelestia-config.git"
CLONE="$HOME/my-caelestia-config"
QS="$HOME/.config/quickshell/caelestia"
CFG="$HOME/.config/caelestia"
fails=0

pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  \e[33mINFO\e[0m  %s\n' "$*"; }
check() {  # check "description" command...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
has() { grep -qF -- "$2" "$1"; }  # has FILE TEXT

echo "Repo"
if [ -d "$CLONE/.git" ]; then
    git -C "$CLONE" fetch -q 2>/dev/null
    check "no uncommitted changes in ~/my-caelestia-config" \
        test -z "$(git -C "$CLONE" status --porcelain)"
    check "everything committed is pushed" \
        test -z "$(git -C "$CLONE" log --oneline '@{u}..HEAD' 2>/dev/null)"
else
    info "no clone at $CLONE; skipping commit/push checks"
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if git clone -q --depth 1 "$REPO" "$tmp/c" 2>/dev/null; then
    rm -rf "$tmp/c/.git"
    stale=()
    while IFS= read -r -d '' f; do
        rel=${f#"$tmp/c/"}
        case "$rel" in home/*) d="$HOME/${rel#home/}" ;; *) d="$CFG/$rel" ;; esac
        cmp -s "$f" "$d" || stale+=("${d/#$HOME/\~}")
    done < <(find "$tmp/c" -type f -print0)
    if [ ${#stale[@]} -eq 0 ]; then
        pass "installed files match GitHub"
    else
        fail "installed files differ from GitHub (run update-config.sh): ${stale[*]}"
    fi
else
    fail "couldn't clone $REPO"
fi

echo "Chrome wallpaper hook"
hook="$HOME/.local/bin/chrome-ntp-wallpaper"
check "hook installed and executable" test -x "$hook"
check "hook is the new version (writes background first, validates colour)" \
    has "$hook" "grep -Eqx '[0-9A-Fa-f]{6}'"
check "cli.json runs the hook and has enableChromium off" python3 -c "
import json, os
c = json.load(open(os.path.expanduser('~/.config/caelestia/cli.json')))
assert c['wallpaper']['postHook'] == '~/.local/bin/chrome-ntp-wallpaper'
assert c['theme']['enableChromium'] is False"
check "passwordless sudo rule for Chrome's policy" \
    sudo -n -l /usr/bin/tee /etc/opt/chrome/policies/managed/caelestia.json
check "Chrome policy file holds a theme colour" \
    grep -q BrowserThemeColor /etc/opt/chrome/policies/managed/caelestia.json
check "Chrome has a custom new tab background to replace" \
    test -f "$HOME/.config/google-chrome/Default/background.jpg"

echo "Sunshine virtual display"
check "start_vd.sh installed, executable, saves layout, checks client mode" \
    bash -c 'f=~/.config/sunshine/start_vd.sh; test -x "$f" && grep -q sunshine_vd.lua "$f" && grep -q "plain numbers only" "$f"'
check "stop_vd.sh deletes the saved layout before re-enabling monitors" \
    bash -c 'f=~/.config/sunshine/stop_vd.sh; r=$(grep -n "rm -f.*sunshine_vd.lua" "$f" | cut -d: -f1); e=$(grep -n "disabled = false" "$f" | head -1 | cut -d: -f1); [ -n "$r" ] && [ -n "$e" ] && [ "$r" -lt "$e" ]'
check "hypr-user.lua re-applies the layout on config reload" \
    bash -c 'grep -q sunshine_vd.lua ~/.config/caelestia/hypr-user.lua && grep -q get_monitor ~/.config/caelestia/hypr-user.lua'
if [ -f "$HOME/.config/sunshine/apps.json" ]; then
    check "a Sunshine app runs start_vd.sh / stop_vd.sh" \
        bash -c 'grep -q start_vd.sh ~/.config/sunshine/apps.json && grep -q stop_vd.sh ~/.config/sunshine/apps.json'
fi
if hyprctl monitors 2>/dev/null | grep -q '^Monitor sunshine_vd'; then
    info "a stream is running now (sunshine_vd exists)"
else
    check "no leftover saved layout while not streaming" \
        test ! -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sunshine_vd.lua"
fi

echo "Caelestia shell patches (hypr-setup.sh patch_caelestia_qml)"
check "monitor lookup is reactive (blurry bar / dead edges fix)" \
    has "$QS/services/Hypr.qml" "Reactive lookup"
check "lock video present" has "$QS/modules/lock/LockSurface.qml" "id: lockVideo"
check "lock video audio follows the default output (stream audio fix)" \
    has "$QS/modules/lock/LockSurface.qml" "mediaDevices.defaultAudioOutput"
check "lock panel opacity applied" has "$QS/modules/lock/LockSurface.qml" "LOCK_PANEL_OPACITY"
check "lock video replays after waking from sleep" has "$QS/modules/lock/LockSurface.qml" "lockVideoWake"
check "Caelestia locks the screen before sleep" python3 -c "
import json, os
assert 'lockBeforeSleep' in open(os.path.expanduser('~/.config/quickshell/caelestia/modules/IdleMonitors.qml')).read()
try:
    s = json.load(open(os.path.expanduser('~/.config/caelestia/shell.json')))
except FileNotFoundError:
    s = {}
assert s.get('general', {}).get('idle', {}).get('lockBeforeSleep', True) is not False"
check "lock screen unlocks the keyring" has "$QS/assets/pam.d/passwd" "pam_gnome_keyring"

echo "Session"
check "start.sh locks on login, then changes wallpaper after unlock" \
    bash -c 'grep -q "ipc call lock lock" ~/.config/caelestia/start.sh && grep -q "wallpaper -r" ~/.config/caelestia/start.sh'
errs=$(hyprctl configerrors 2>/dev/null | grep -v '^\s*$')
if [ -z "$errs" ] || printf '%s' "$errs" | grep -qi 'no errors'; then
    pass "Hyprland config has no errors"
else
    fail "Hyprland config errors: $errs"
fi
for u in hypridle.service hyprpaper.service; do
    state=$(systemctl --user is-enabled "$u" 2>/dev/null)
    case "$state" in
        enabled*) fail "$u is enabled (hypridle suspends the PC; disable with: systemctl --user disable --now $u)" ;;
        *) pass "$u not enabled (${state:-not installed})" ;;
    esac
done
email=$(git config --global user.email)
case "$email" in
    *noreply.github.com) pass "git commits use your private GitHub email" ;;
    *) info "git commit email is '${email:-unset}' (see the noreply tip)" ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "All checks passed."; else echo "$fails check(s) failed."; fi
