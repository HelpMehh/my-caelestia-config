#!/usr/bin/env bash
# Pull my config repo and install it:
#   home/...   -> the same path under ~   (home/.config/sunshine/start_vd.sh
#                                          -> ~/.config/sunshine/start_vd.sh)
#   the rest   -> ~/.config/caelestia/
# Edit and commit in a separate clone of the repo; this only installs it.
set -euo pipefail

REPO="https://github.com/HelpMehh/my-caelestia-config.git"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Restoring personal config from Git..."
git clone --depth 1 -q "$REPO" "$tmp/config"
rm -rf "$tmp/config/.git"

if [ -d "$tmp/config/home" ]; then
    find "$tmp/config/home" -type f \( -name '*.sh' -o -path '*/.local/bin/*' \) \
        -exec chmod +x {} +
    cp -a "$tmp/config/home/." "$HOME/"
    (cd "$tmp/config/home" && find . -type f | sed 's|^\./|  installed ~/|')
    rm -rf "$tmp/config/home"
fi

mkdir -p "$HOME/.config/caelestia"
cp -a "$tmp/config/." "$HOME/.config/caelestia/"

echo "Personal config restored successfully!"
