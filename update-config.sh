#!/usr/bin/env bash
# Pull my config repo and install it:
#   home/...   -> the same path under ~   (home/.config/sunshine/start_vd.sh
#                                          -> ~/.config/sunshine/start_vd.sh)
#   the rest   -> ~/.config/caelestia/
# Edit and commit in a separate clone of the repo; this only installs it.
#
# Everything in the repo ends up running on this machine (start.sh at login,
# hypr-user.lua in Hyprland, scripts in ~/.local/bin...), so it shows what
# would change and asks before installing. -y skips the question.
set -euo pipefail

REPO="https://github.com/HelpMehh/my-caelestia-config.git"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Fetching personal config from Git..."
git clone --depth 1 -q "$REPO" "$tmp/config"
echo "Latest commit: $(git -C "$tmp/config" log -1 --format='%h %an, %ar: %s')"
rm -rf "$tmp/config/.git"

dest_for() {  # repo path -> installed path
    case "$1" in
        home/*) printf '%s\n' "$HOME/${1#home/}" ;;
        *)      printf '%s\n' "$HOME/.config/caelestia/$1" ;;
    esac
}

changes=0
while IFS= read -r -d '' f; do
    rel=${f#"$tmp/config/"}
    dest=$(dest_for "$rel")
    if [ ! -e "$dest" ]; then
        echo; echo "NEW      ${dest/#$HOME/\~}"
        sed 's/^/    + /' "$f" | head -n 40
        changes=1
    elif ! cmp -s "$f" "$dest"; then
        echo; echo "CHANGED  ${dest/#$HOME/\~}"
        { diff -u "$dest" "$f" || true; } | tail -n +3 | sed 's/^/    /'
        changes=1
    fi
done < <(find "$tmp/config" -type f -print0 | sort -z)

if [ "$changes" -eq 0 ]; then
    echo "Already up to date; nothing to install."
    exit 0
fi

echo
if [ "${1:-}" != "-y" ]; then
    read -rp "Install these changes? [y/N] " answer
    case "$answer" in
        [yY]*) ;;
        *) echo "Nothing installed."; exit 1 ;;
    esac
fi

if [ -d "$tmp/config/home" ]; then
    find "$tmp/config/home" -type f \( -name '*.sh' -o -path '*/.local/bin/*' \) \
        -exec chmod +x {} +
    cp -a "$tmp/config/home/." "$HOME/"
    rm -rf "$tmp/config/home"
fi

mkdir -p "$HOME/.config/caelestia"
cp -a "$tmp/config/." "$HOME/.config/caelestia/"

echo "Personal config installed."
