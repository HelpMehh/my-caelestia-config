#!/usr/bin/env bash
#
# hypr-setup.sh — Hyprland + Caelestia deployment for Ubuntu
#
# Builds Hyprland (via hyprbuntu), Quickshell, Caelestia shell/CLI, the Hyprland
# xdg-desktop-portal and gpu-screen-recorder from source, applies the local QML
# compatibility patches, restores personal config from git, installs the
# systemd user units the session needs, and wires up desktop integration
# (GTK theme, Thunar as file manager, default browser, Sunshine).
#
# Usage:
#   ./hypr-setup.sh                  full install on a fresh machine
#   ./hypr-setup.sh update           update everything it installed (see update())
#   ./hypr-setup.sh update sunshine  update only some parts
#   ./hypr-setup.sh <step>...        run single steps, e.g. patch_caelestia_qml
#
# Install phases can be skipped individually, e.g.:
#   SKIP_HYPRBUNTU=1 SKIP_GSR=1 ./hypr-setup.sh
#
# Run it from inside a logged-in Hyprland session: several steps (gsettings,
# xdg-mime, systemctl --user) need the session's D-Bus.
#
# Every phase is idempotent: re-running is safe. For keeping an installed
# machine current, use `update` rather than a full rerun: a full install
# redeploys Caelestia's stock config files.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PERSONAL_CONFIG_REPO="${PERSONAL_CONFIG_REPO:-https://github.com/HelpMehh/my-caelestia-config.git}"
ADW_GTK3_VERSION="${ADW_GTK3_VERSION:-v6.5}"
# Video shown behind Caelestia's lock screen (skipped if the file doesn't exist).
LOCK_VIDEO="${LOCK_VIDEO:-$HOME/Wallpaper/lockscreen.mp4}"
# Space-separated monitors it plays on ("" = every monitor, decoding it once per
# screen). sunshine_vd is the virtual display start_vd.sh creates for streams;
# the physical monitors are disabled while it exists, so only one plays at a time.
LOCK_VIDEO_SCREENS="${LOCK_VIDEO_SCREENS:-DP-2 sunshine_vd}"
# Audio: "once" plays it on the first pass and loops silently after, so an idle
# lock doesn't repeat it for hours; "always" plays it every loop; "off" mutes it.
LOCK_VIDEO_AUDIO="${LOCK_VIDEO_AUDIO:-always}"
# How opaque the lock screen's panel and its cards are, 0-1. Lower lets more of
# the video show through; 1 is Caelestia's normal look. Only the backgrounds
# fade, not the text. Try another value without a full run:
#   LOCK_PANEL_OPACITY=0.5 ./hypr-setup.sh patch_caelestia_qml
LOCK_PANEL_OPACITY="${LOCK_PANEL_OPACITY:-0.2}"

# Where each source-built component comes from, and which version gets built:
# HEAD (newest code), latest-tag (newest release), a tag, a branch or a commit.
# Caelestia is developed against Quickshell's newest code, so those three
# track HEAD. Set one to a tag or commit to pin it; `update` then leaves it
# there until you change it.
QUICKSHELL_URL="https://github.com/outfoxxed/quickshell.git"
QUICKSHELL_REF="${QUICKSHELL_REF:-HEAD}"
CAELESTIA_SHELL_URL="https://github.com/caelestia-dots/shell.git"
CAELESTIA_SHELL_REF="${CAELESTIA_SHELL_REF:-HEAD}"
CAELESTIA_CLI_URL="https://github.com/caelestia-dots/cli.git"
CAELESTIA_CLI_REF="${CAELESTIA_CLI_REF:-HEAD}"
# The cava fork Caelestia is written against: it installs a shared libcava
# with pkg-config and headers under cava/. Upstream karlstav/cava no longer
# installs a library, and its cava_init() takes an extra argument.
LIBCAVA_URL="https://github.com/LukashonakV/cava.git"
LIBCAVA_REF="${LIBCAVA_REF:-latest-tag}"
CAELESTIA_DOTS_URL="https://github.com/caelestia-dots/caelestia.git"
GSR_URL="https://repo.dec05eba.com/gpu-screen-recorder"

# Which version of each component is installed, so `update` only rebuilds
# what changed upstream (and retries anything that failed last time).
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-setup"
STATE_FILE="$STATE_DIR/versions"
# UPDATE_YES=1: don't ask before updating.
UPDATE_YES="${UPDATE_YES:-0}"

SKIP_HYPRBUNTU="${SKIP_HYPRBUNTU:-0}"
SKIP_CAELESTIA="${SKIP_CAELESTIA:-0}"
SKIP_PORTAL="${SKIP_PORTAL:-0}"
SKIP_GSR="${SKIP_GSR:-0}"
SKIP_SYSTEM_FIXES="${SKIP_SYSTEM_FIXES:-0}"
SKIP_DESKTOP="${SKIP_DESKTOP:-0}"

LOG_FILE="${LOG_FILE:-$HOME/hypr-setup-$(date +%Y%m%d-%H%M%S).log}"

export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$PATH"
export LOG_FILE

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

# Steps that run_step() starts as child processes log through the parent.
[[ -n "${HYPR_SETUP_CHILD:-}" ]] || exec > >(tee -a "$LOG_FILE") 2>&1

BUILD_DIR=""
SUDO_KEEPALIVE_PID=""
SHELL_STOPPED=0

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2
    exit 1
}

on_error() {
    local line=$1
    printf '\n\033[1;31m[fail]\033[0m %s failed at line %s. Full log: %s\n' \
        "${BASH_SOURCE[0]}" "$line" "$LOG_FILE" >&2
}

cleanup() {
    # An update that stopped the shell and then failed still brings it back.
    [[ "$SHELL_STOPPED" == 1 ]] && start_shell || true
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR" || true
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    log "Preflight checks"

    [[ $EUID -ne 0 ]] || die "Do not run this script as root. It calls sudo where needed."

    command -v apt-get >/dev/null || die "This script targets Debian/Ubuntu (apt-get not found)."

    # Take the sudo password once, then refresh it in the background. Builds run
    # long enough that the timestamp would otherwise expire mid-run and stall.
    info "Requesting sudo up front so the build doesn't stall later..."
    sudo -v || die "sudo authentication failed."
    (
        set +eE
        trap - ERR
        while true; do
            sudo -n true 2>/dev/null
            sleep 50
            kill -0 "$$" 2>/dev/null || exit 0
        done
    ) &
    SUDO_KEEPALIVE_PID=$!

    # Everything else this script needs is downloaded or generated as it runs
    # (hyprbuntu from GitLab, sources from GitHub, units and wrappers inline),
    # so these two are the only prerequisites. Install them on a fresh system.
    local missing=()
    command -v git >/dev/null || missing+=(git)
    command -v curl >/dev/null || missing+=(curl)
    if ((${#missing[@]})); then
        info "Installing prerequisites: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}" ca-certificates
    fi

    info "Logging to $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Base build dependencies
#
# NOTE: power-profiles-daemon is deliberately NOT installed here.
# On this machine GDM autologins ~12s into boot, so Hyprland and Caelestia start
# while the system is still booting. Quickshell touches xdg-desktop-portal, the
# portal synchronously activates org.freedesktop.UPower.PowerProfiles on the
# system bus, and that service cannot start until multi-user.target is reached —
# which plymouth-quit-wait.service holds open for ~11s. Net result was a hard
# 8-second stall before the shell appeared. See the mask in apply_system_fixes().
# ---------------------------------------------------------------------------

install_base_packages() {
    log "Installing build dependencies"

    sudo apt-get update
    sudo apt-get install -y \
        qt6-base-dev \
        qt6-base-private-dev \
        qt6-declarative-dev \
        qt6-declarative-private-dev \
        qt6-declarative-dev-tools \
        qt6-wayland-dev \
        qt6-wayland-private-dev \
        qt6-shadertools-dev \
        qt6-image-formats-plugins \
        qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts \
        qml6-module-qtquick-templates \
        libpipewire-0.3-dev \
        libqalculate-dev \
        libaubio-dev \
        libddcutil-dev \
        libcli11-dev \
        libjemalloc-dev \
        libunwind-dev \
        libfftw3-dev \
        libfftw3-single3 \
        libfftw3-double3 \
        libasound2-dev \
        libpulse-dev \
        libtool \
        automake \
        autoconf \
        autoconf-archive \
        wayland-protocols \
        lm-sensors \
        libsensors-dev \
        brightnessctl \
        swappy \
        network-manager \
        fish \
        bash \
        python3-pip \
        python3-setuptools \
        libiniparser-dev \
        cliphist \
        hyprpicker \
        fuzzel \
        ydotool \
        vlc \
        pkg-config \
        cmake \
        ninja-build \
        meson \
        libwayland-dev \
        libdrm-dev \
        libgbm-dev \
        libsystemd-dev \
        libsdbus-c++-dev \
        libxcomposite-dev \
        libxrandr-dev \
        libxfixes-dev \
        libcap-dev \
        libva-dev \
        papirus-icon-theme \
        dconf-cli \
        qml6-module-qtmultimedia
    # papirus-icon-theme: Caelestia switches the GTK icon theme between
    #   Papirus-Dark and Papirus-Light with the colour scheme.
    # dconf-cli: Caelestia applies the GTK theme with `dconf write`.
    # qml6-module-qtmultimedia: plays the lock screen video.
}

# ---------------------------------------------------------------------------
# Hyprland via hyprbuntu
# ---------------------------------------------------------------------------

run_hyprbuntu() {
    log "Building Hyprland via hyprbuntu"

    local bin_dir="$HOME/.local/bin"
    local script="$bin_dir/setup-hyprbuntu.sh"
    mkdir -p "$bin_dir"

    # -f so an HTTP error is an error rather than a saved error page we then
    # chmod +x and execute.
    curl -fsSL --proto '=https' --tlsv1.2 \
        -o "$script" \
        "https://gitlab.com/kralos/hyprbuntu/-/raw/main/setup-hyprbuntu.sh" ||
        die "Could not download setup-hyprbuntu.sh"

    [[ -s "$script" ]] || die "Downloaded setup-hyprbuntu.sh is empty."

    # HYPRIDLE_SETUP=false: Caelestia already handles idle itself (lock at 3 min,
    # screen off at 5 min, suspend-then-hibernate at 10 min, all paused by its
    # Keep Awake toggle).
    # hyprbuntu's hypridle config ALSO runs `systemctl suspend` after 10 minutes
    # on desktops, and once graphical-session.target is bound (start.sh does
    # that for Sunshine) hypridle actually runs -- the likely reason this
    # machine slept despite Keep Awake. HYPRPAPER_SETUP=false for the same reason:
    # Caelestia draws the wallpaper, and hyprpaper.service would start (and
    # crash) with the session target too.

    # Skip packages Caelestia replaces.
    sed -i '/install_hyprwm_package hyprlauncher/,+2 s/^/# /' "$script"
    sed -i '/install_hyprwm_package hyprshutdown/ s/^/# /' "$script"
    chmod +x "$script"

    THEME_PREF=dark \
        NOTIFICATION_DAEMON_PREF=none \
        HYPRPAPER_SETUP=false \
        HYPRLOCK_SETUP=false \
        HYPRIDLE_SETUP=false \
        HYPRSHOT_SETUP=true \
        SWAYOSD_SETUP=false \
        THUNAR_SETUP=true \
        WAYBAR_SETUP=false \
        NVIDIA_SETUP=true \
        DISABLE_CONFIRM=true \
        "$script"
}

# ---------------------------------------------------------------------------
# Source builds: shared helpers
#
# Every component is built from an exact commit, and that commit is recorded
# in $STATE_FILE once it's installed. update() compares the records with
# upstream, so a rerun only rebuilds what changed and retries what failed.
# ---------------------------------------------------------------------------

state_get() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
}

state_set() {
    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/.versions.XXXXXX")
    {
        grep -v "^$1=" "$STATE_FILE" 2>/dev/null || true
        printf '%s=%s\n' "$1" "$2"
    } >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

# Newest release tag of a git repo, by version number (a leading "v" is
# ignored, pre-releases are skipped). Empty if there are none.
latest_tag() {
    git ls-remote --tags --refs "$1" 2>/dev/null |
        sed 's|.*refs/tags/||' |
        grep -viE '(alpha|beta|rc|pre|dev)' |
        awk '{ v = $0; sub(/^[vV]/, "", v); print v "\t" $0 }' |
        sort -t "$(printf '\t')" -k1,1V | tail -n 1 | cut -f2 || true
}

# resolve_ref URL REF -> the commit REF points at. REF is HEAD, latest-tag,
# a tag, a branch or a full commit hash. Fails if it can't be resolved.
resolve_ref() {
    local url=$1 ref=$2 out
    if [[ "$ref" == latest-tag ]]; then ref=$(latest_tag "$url"); fi
    [[ -n "$ref" ]] || return 1
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s\n' "$ref"
        return 0
    fi
    out=$(git ls-remote "$url" "$ref" 2>/dev/null) || return 1
    # An annotated tag lists the tag object and, with ^{}, its commit.
    printf '%s\n' "$out" | awk -v ref="$ref" '
        $2 ~ /\^\{\}$/ { peeled = $1 }
        $2 == ref || $2 == "refs/tags/" ref || $2 == "refs/heads/" ref { direct = $1 }
        END { c = peeled ? peeled : direct; if (c == "") exit 1; print c }'
}

# fetch_at URL COMMIT DIR: DIR becomes a shallow checkout of exactly COMMIT.
fetch_at() {
    rm -rf "$3"
    mkdir -p "$3"
    git -C "$3" init -q
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

short() { if [[ -n "${1:-}" ]]; then printf '%.7s' "$1"; else printf 'unknown'; fi; }

# ---------------------------------------------------------------------------
# Quickshell, libcava, Caelestia shell plugin + QML, Caelestia CLI
#
# build_* only compile (as you, into a scratch directory); install_* copy the
# result into place with sudo. update() builds everything before installing
# anything, so a failed build never leaves a half-updated setup.
# ---------------------------------------------------------------------------

build_quickshell() { # SRC COMMIT
    log "Building Quickshell $(short "$2")"
    cmake -S "$1" -B "$1/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DVENDOR_CPPTRACE=ON \
        -DGIT_REVISION="$2"
    cmake --build "$1/build"
}

install_quickshell() { # SRC COMMIT
    sudo cmake --install "$1/build"
    state_set quickshell "$2"
}

build_libcava() { # SRC
    log "Building libcava"
    meson setup "$1/build" "$1" --prefix=/usr --buildtype=release -Dbuild_target=lib
    meson compile -C "$1/build"
}

install_libcava() { # SRC COMMIT
    sudo meson install -C "$1/build"
    sudo ldconfig
    state_set libcava "$2"
}

build_caelestia_plugin() { # SRC COMMIT
    log "Building Caelestia shell plugin $(short "$2")"
    # A shallow checkout has no tags for the build's `git describe`.
    local version
    version=$(latest_tag "$CAELESTIA_SHELL_URL")
    version=${version#v}
    cmake -S "$1" -B "$1/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DVERSION="${version:-0.0.0}" \
        -DGIT_REVISION="$2"
    cmake --build "$1/build"
}

install_caelestia_plugin() { # SRC
    sudo cmake --install "$1/build"
}

# The shell's QML runs from ~/.config/quickshell/caelestia, a git checkout the
# patches in patch_caelestia_qml() are applied to. It has to be at the same
# commit as the plugin, or the two halves of the shell don't match.
sync_shell_qml() { # COMMIT
    local dir="$HOME/.config/quickshell/caelestia"
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null ||
            git -C "$dir" fetch -q --depth 1 "$CAELESTIA_SHELL_URL" "$1"
        git -C "$dir" checkout -q -- .
        git -C "$dir" reset -q --hard "$1"
    else
        if [[ -e "$dir" ]]; then
            local bak
            bak="$dir.bak.$(date +%Y%m%d_%H%M%S)"
            warn "$dir isn't a git checkout; moving it to $bak"
            mv "$dir" "$bak"
        fi
        mkdir -p "$(dirname "$dir")"
        fetch_at "$CAELESTIA_SHELL_URL" "$1" "$dir"
    fi
}

# Built into a wheel first, so a failed build never leaves a half-installed
# CLI. Installed system-wide (/usr/local/bin) so Hyprland keybinds find it
# without depending on the user's PATH.
build_caelestia_cli() { # SRC
    log "Building Caelestia CLI"
    local version
    version=$(latest_tag "$CAELESTIA_CLI_URL")
    version=${version#v}
    SETUPTOOLS_SCM_PRETEND_VERSION="${version:-0.0.0}" \
        python3 -m pip wheel --quiet --no-deps --wheel-dir "$1/dist" "$1"
}

install_caelestia_cli() { # SRC COMMIT
    local wheel
    wheel=$(find "$1/dist" -name 'caelestia-*.whl' | head -n 1)
    [[ -n "$wheel" ]] || die "Caelestia CLI wheel not found in $1/dist"
    # A new commit usually keeps the version number, so force the reinstall;
    # the second pass adds any dependencies the new version needs.
    sudo pip3 install --break-system-packages --force-reinstall --no-deps "$wheel"
    sudo pip3 install --break-system-packages "$wheel"
    state_set caelestia-cli "$2"
}

build_caelestia_ecosystem() {
    log "Building Caelestia ecosystem"

    BUILD_DIR=$(mktemp -d -p "$HOME" .hypr-build.XXXXXX)
    info "Build directory: $BUILD_DIR (removed on exit)"

    local qs_c cava_c shell_c cli_c
    qs_c=$(resolve_ref "$QUICKSHELL_URL" "$QUICKSHELL_REF") ||
        die "Can't resolve Quickshell $QUICKSHELL_REF"
    cava_c=$(resolve_ref "$LIBCAVA_URL" "$LIBCAVA_REF") ||
        die "Can't resolve libcava $LIBCAVA_REF"
    shell_c=$(resolve_ref "$CAELESTIA_SHELL_URL" "$CAELESTIA_SHELL_REF") ||
        die "Can't resolve Caelestia shell $CAELESTIA_SHELL_REF"
    cli_c=$(resolve_ref "$CAELESTIA_CLI_URL" "$CAELESTIA_CLI_REF") ||
        die "Can't resolve Caelestia CLI $CAELESTIA_CLI_REF"

    fetch_at "$QUICKSHELL_URL" "$qs_c" "$BUILD_DIR/quickshell"
    build_quickshell "$BUILD_DIR/quickshell" "$qs_c"
    install_quickshell "$BUILD_DIR/quickshell" "$qs_c"

    fetch_at "$LIBCAVA_URL" "$cava_c" "$BUILD_DIR/libcava"
    build_libcava "$BUILD_DIR/libcava"
    install_libcava "$BUILD_DIR/libcava" "$cava_c"

    fetch_at "$CAELESTIA_SHELL_URL" "$shell_c" "$BUILD_DIR/caelestia-shell"
    build_caelestia_plugin "$BUILD_DIR/caelestia-shell" "$shell_c"
    install_caelestia_plugin "$BUILD_DIR/caelestia-shell"
    sync_shell_qml "$shell_c"
    state_set caelestia-shell "$shell_c"

    log "Installing Caelestia CLI"
    fetch_at "$CAELESTIA_CLI_URL" "$cli_c" "$BUILD_DIR/caelestia-cli"
    build_caelestia_cli "$BUILD_DIR/caelestia-cli"
    install_caelestia_cli "$BUILD_DIR/caelestia-cli" "$cli_c"

    command -v caelestia >/dev/null || die "caelestia CLI not on PATH after install."

    # --- Upstream dotfiles (fresh installs only; update() never runs this) ---
    log "Deploying upstream dotfiles"
    git clone --depth 1 "$CAELESTIA_DOTS_URL" "$BUILD_DIR/caelestia-dots"

    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    if [[ -d "$HOME/.config/hypr" ]]; then
        info "Backing up ~/.config/hypr -> hypr.bak.$stamp"
        mv "$HOME/.config/hypr" "$HOME/.config/hypr.bak.$stamp"
    fi
    if [[ -d "$HOME/.config/caelestia" ]]; then
        info "Backing up ~/.config/caelestia -> caelestia.bak.$stamp"
        mv "$HOME/.config/caelestia" "$HOME/.config/caelestia.bak.$stamp"
    fi

    mkdir -p "$HOME/.config"
    # Without its .git, or ~/.config itself would become a git checkout.
    rm -rf "$BUILD_DIR/caelestia-dots/.git"
    # Trailing /. so dotfiles in the repo root are copied too; cp -r src/* skips them.
    cp -a "$BUILD_DIR/caelestia-dots/." "$HOME/.config/"

    # Placeholders only — the real contents come from the personal config repo
    # in restore_personal_config(). Written unconditionally so a fresh machine
    # has valid Lua even if the repo restore is skipped.
    mkdir -p "$HOME/.config/caelestia"
    [[ -f "$HOME/.config/caelestia/hypr-vars.lua" ]] || echo "return {}" >"$HOME/.config/caelestia/hypr-vars.lua"
    [[ -f "$HOME/.config/caelestia/hypr-user.lua" ]] || echo "" >"$HOME/.config/caelestia/hypr-user.lua"

    caelestia install || warn "caelestia install returned non-zero; continuing."

    rm -rf "$BUILD_DIR"
    BUILD_DIR=""
    log "Caelestia ecosystem built"
}

# ---------------------------------------------------------------------------
# xdg-desktop-portal-hyprland
#
# Ubuntu's packaged portal is too old for a source-built Hyprland, and without a
# matching portal Sunshine, OBS and Discord cannot capture the screen. Current
# hyprbuntu builds it (at its latest release) alongside Hyprland, so this only
# runs when hyprbuntu is skipped or doesn't.
# ---------------------------------------------------------------------------

hyprbuntu_builds_portal() {
    grep -q 'install_hyprwm_package xdg-desktop-portal-hyprland' \
        "$HOME/.local/bin/setup-hyprbuntu.sh" 2>/dev/null
}

build_portal() {
    log "Building xdg-desktop-portal-hyprland"

    local dir
    dir=$(mktemp -d)
    git clone --depth 1 --recursive \
        https://github.com/hyprwm/xdg-desktop-portal-hyprland.git "$dir/xdph"
    cmake -S "$dir/xdph" -B "$dir/xdph/build" -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build "$dir/xdph/build"
    sudo cmake --install "$dir/xdph/build"
    rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# gpu-screen-recorder (its install.sh builds and installs in one go)
# ---------------------------------------------------------------------------

build_gpu_screen_recorder() {
    log "Building gpu-screen-recorder"

    local dir
    dir=$(mktemp -d)
    git clone -q --depth 1 "$GSR_URL" "$dir/gsr"
    (cd "$dir/gsr" && sudo ./install.sh)
    state_set gsr "$(git -C "$dir/gsr" rev-parse HEAD)"
    rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# QML compatibility patches
#
# Caelestia targets Arch's Qt6, which is ahead of Ubuntu's. These patch out the
# QML features Ubuntu's Qt doesn't have yet.
# ---------------------------------------------------------------------------

patch_caelestia_qml() {
    log "Patching Caelestia QML for Ubuntu's Qt6"

    local dir="$HOME/.config/quickshell/caelestia"

    if [[ ! -d "$dir" ]]; then
        # Same commit as the installed plugin, if we know it.
        info "Shell QML missing; fetching it."
        local commit
        commit=$(state_get caelestia-shell)
        if [[ -z "$commit" ]]; then
            commit=$(resolve_ref "$CAELESTIA_SHELL_URL" "$CAELESTIA_SHELL_REF") ||
                die "Can't resolve Caelestia shell $CAELESTIA_SHELL_REF"
        fi
        sync_shell_qml "$commit"
    fi

    cd "$dir" || die "Cannot enter $dir"

    # Reset so patches apply cleanly on a re-run rather than stacking.
    git checkout -- . 2>/dev/null || warn "Could not git-reset $dir; patches may stack."

    # 'char' is reserved in Ubuntu's QML parser.
    find . -type f -name "InputField.qml" -exec sed -i 's/\bchar\b/charItem/g' {} +
    # DoubleSpinBox / decimals are newer than Ubuntu's QtQuick.Controls.
    find . -type f -name "StyledSpinBox.qml" -exec sed -i 's/DoubleSpinBox/SpinBox/g' {} +
    find . -type f -name "StyledSpinBox.qml" -exec sed -i '/decimals:/s/^/\/\//' {} +

    # Per-corner radius properties need Qt 6.7+.
    python3 - <<'PY'
import glob, re

pattern = re.compile(r"^\s*(topLeft|topRight|bottomLeft|bottomRight)Radius\s*:")
patched = 0

for path in glob.glob("**/*.qml", recursive=True):
    with open(path) as f:
        lines = f.readlines()
    out = ["// " + l if pattern.search(l) else l for l in lines]
    if out != lines:
        with open(path, "w") as f:
            f.writelines(out)
        patched += 1

print(f"    commented per-corner radius properties in {patched} file(s)")
PY

    # Default recordings to VLC for playback.
    find "$dir" -type f -name "RecordingList.qml" \
        -exec sed -i 's/\.\.\.GlobalConfig\.general\.apps\.playback/"vlc"/g' {} +

    # Unlock the GNOME keyring when the lock screen is unlocked. Caelestia's lock
    # uses its own PAM file (not the system's), which only checks the password.
    # pam_gnome_keyring passes the password to the running keyring daemon, so
    # autologin + lock-on-startup doesn't mean typing the password twice.
    local pam_file="assets/pam.d/passwd"
    if [[ -f "$pam_file" ]] && ! grep -q pam_gnome_keyring "$pam_file"; then
        echo 'auth    optional    pam_gnome_keyring.so' >>"$pam_file"
        info "lock screen now unlocks the GNOME keyring"
    fi

    # Play a video behind the lock screen. While locked, Wayland shows only the
    # lock surfaces, so the lock screen has to play it itself. It sits above
    # Caelestia's blurred background (so it isn't blurred), fades in and out
    # with it, and is destroyed on unlock, so the static wallpaper comes back
    # on its own. Only the chosen screens create a player.
    LOCK_VIDEO="$LOCK_VIDEO" LOCK_VIDEO_SCREENS="$LOCK_VIDEO_SCREENS" \
        LOCK_VIDEO_AUDIO="$LOCK_VIDEO_AUDIO" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path("modules/lock/LockSurface.qml")
if not p.exists():
    print("    [warn] LockSurface.qml not found; lock video not added")
    raise SystemExit
s = p.read_text()
anchor = "    Component {\n        id: screencopyBackground"
if "id: lockVideo" in s:
    print("    lock video already present")
elif anchor not in s or "import QtQuick.Effects\n" not in s:
    print("    [warn] LockSurface.qml has changed upstream; lock video not added")
else:
    video = json.dumps(os.environ["LOCK_VIDEO"])
    screens = json.dumps(os.environ["LOCK_VIDEO_SCREENS"].split())
    audio = json.dumps(os.environ["LOCK_VIDEO_AUDIO"])
    block = f"""    // Lock screen video (added by hypr-setup.sh)
    Loader {{
        id: lockVideo

        readonly property string videoPath: {video}
        readonly property var videoScreens: {screens}
        readonly property string audioMode: {audio}
        property bool restarting: false

        // Tear the player down and build a new one: the video starts over
        // (with sound in "once" mode) on a fresh decoder.
        function restart(): void {{
            restarting = true;
            Qt.callLater(() => lockVideo.restarting = false);
        }}

        anchors.fill: parent
        opacity: background.opacity
        active: !restarting && (videoScreens.length === 0 || videoScreens.includes(root.screen.name))

        sourceComponent: Item {{
            visible: player.hasVideo

            VideoOutput {{
                id: videoOut

                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectCrop
            }}

            // Qt picks the default sink once, when the player is created, and
            // never follows it. Sunshine creates sunshine_vd (and with it this
            // player) a couple of seconds before it switches the default sink
            // to its own, so bind the device to keep up with the switch.
            MediaDevices {{
                id: mediaDevices
            }}

            MediaPlayer {{
                id: player

                property int lastPosition: 0

                source: "file://" + lockVideo.videoPath
                videoOutput: videoOut
                audioOutput: AudioOutput {{
                    id: audioOut

                    device: mediaDevices.defaultAudioOutput
                    muted: lockVideo.audioMode === "off"
                }}
                loops: MediaPlayer.Infinite

                // Position jumps back to the start on each loop.
                onPositionChanged: {{
                    if (lockVideo.audioMode === "once" && position < lastPosition)
                        audioOut.muted = true;
                    lastPosition = position;
                }}
                Component.onCompleted: play()
            }}
        }}
    }}

    // Replay the video when the PC wakes up. Caelestia locks just before
    // sleep, so the player starts as the PC goes down and comes back mid-way
    // (or with a decoder the suspend broke). Timers don't count time spent
    // suspended but the wall clock does, so a big jump between ticks means
    // we just resumed.
    Timer {{
        id: lockVideoWake

        property real lastTick: Date.now()

        interval: 1000
        running: lockVideo.active
        repeat: true
        onTriggered: {{
            const now = Date.now();
            if (now - lastTick > 5000)
                lockVideo.restart();
            lastTick = now;
        }}
    }}

"""
    s = s.replace("import QtQuick.Effects\n", "import QtQuick.Effects\nimport QtMultimedia\n", 1)
    s = s.replace(anchor, block + anchor, 1)
    p.write_text(s)
    print("    lock screen video added")
PY

    # Let the video show through the lock screen's panel. The panel (lockBg) is
    # opaque unless Caelestia's shell-wide transparency is on, and the cards on
    # it (clock, weather, media, password box...) use the transparency-aware
    # palette, so scale both -- only on the lock screen, not the rest of the shell.
    LOCK_PANEL_OPACITY="$LOCK_PANEL_OPACITY" python3 - <<'PY'
import os, pathlib, re
try:
    k = float(os.environ["LOCK_PANEL_OPACITY"])
except ValueError:
    k = -1
if not 0 <= k <= 1:
    print(f"    [warn] LOCK_PANEL_OPACITY={os.environ['LOCK_PANEL_OPACITY']!r} isn't 0-1; lock panel left as is")
    raise SystemExit
if k == 1:
    raise SystemExit

surface = pathlib.Path("modules/lock/LockSurface.qml")
old = "opacity: Colours.transparency.enabled ? Colours.transparency.base : 1\n"
s = surface.read_text() if surface.exists() else ""
if "LOCK_PANEL_OPACITY" in s:
    print("    lock panel opacity already patched")
    raise SystemExit
if s.count(old) != 1:
    print("    [warn] lock panel changed upstream; opacity not patched")
    raise SystemExit
surface.write_text(s.replace(old, f"opacity: {k} * (Colours.transparency.enabled ? Colours.transparency.base : 1) // LOCK_PANEL_OPACITY (hypr-setup.sh)\n"))

cards = 0
for f in pathlib.Path("modules/lock").rglob("*.qml"):
    t = f.read_text()
    new, n = re.subn(r"Colours\.tPalette\.(\w+)", rf"Qt.alpha(Colours.tPalette.\1, Colours.tPalette.\1.a * {k})", t)
    if n:
        f.write_text(new)
        cards += n
print(f"    lock panel at {k:g} opacity ({cards} card colours scaled)")
PY

    # Make the shell's screen -> Hyprland monitor lookup reactive. Upstream uses
    # Hyprland.monitorFor(), a one-shot lookup: if a screen's windows are created
    # before Quickshell sees Hyprland's monitoradded event (it's a race -- e.g.
    # when stop_vd.sh re-enables the monitors after a stream), that screen keeps
    # a null monitor until the shell restarts. The bar then blurs the workspace
    # indicator (it reads "no special workspace name" as "on a special
    # workspace"), and the drawers window widens its input mask by the drag
    # threshold, so clicks near the screen edges never reach the windows.
    # Looking the monitor up through Hyprland.monitors makes every binding that
    # calls Hypr.monitorFor() re-run when the monitor shows up.
    python3 - <<'PY'
import pathlib, re
p = pathlib.Path("services/Hypr.qml")
old = "        return Hyprland.monitorFor(screen);\n"
new = ("        // Reactive lookup (added by hypr-setup.sh): re-evaluates when monitors are\n"
       "        // added, so screens created before Hyprland's monitoradded event still\n"
       "        // get their monitor.\n"
       "        return Hyprland.monitors.values.find(m => m.name === screen?.name) ?? Hyprland.monitorFor(screen);\n")
if not p.exists():
    print("    [warn] services/Hypr.qml not found; monitor lookup not patched")
elif "Reactive lookup" in p.read_text():
    print("    monitor lookup already patched")
elif old not in p.read_text():
    print("    [warn] Hypr.monitorFor changed upstream; monitor lookup not patched")
else:
    p.write_text(p.read_text().replace(old, new, 1))
    print("    monitor lookup made reactive")

direct = [str(f) for f in pathlib.Path(".").rglob("*.qml")
          if f != p and "Hyprland.monitorFor(" in f.read_text()]
if direct:
    print("    [warn] these still call Hyprland.monitorFor() directly:", ", ".join(direct))
PY

    # A command to reload the shell: qs -c caelestia ipc call hypr reloadShell.
    # Windows built while monitors come back from a stream can still end up
    # stale, and a reload rebuilds them; stop_vd.sh calls this a few seconds
    # after a stream ends. (Touching a file doesn't reload: Quickshell ignores
    # changes that leave the contents the same.)
    python3 - <<'PY'
import pathlib
p = pathlib.Path("services/Hypr.qml")
anchor = '        target: "hypr"\n'
fn = ('        // Added by hypr-setup.sh: rebuild the shell\'s windows.\n'
      '        function reloadShell(): void {\n'
      '            Qt.callLater(() => Quickshell.reload(false));\n'
      '        }\n\n')
s = p.read_text() if p.exists() else ""
if "function reloadShell" in s:
    print("    reloadShell already present")
elif anchor not in s:
    print("    [warn] hypr IPC handler not found; reloadShell not added")
else:
    p.write_text(s.replace(anchor, fn + anchor, 1))
    print("    added: qs -c caelestia ipc call hypr reloadShell")
PY

    cd "$HOME"
}

# ---------------------------------------------------------------------------
# Caelestia CLI patches
#
# gpu-screen-recorder can't enumerate Wayland outputs on this setup (its
# --list-capture-options only offers "portal"), and the CLI passes the focused
# monitor's name -- which is also sunshine_vd while streaming. Force portal
# capture. Recordings go to .mkv because gsr warns this FFmpeg's fragmented-MP4
# support is broken.
# ---------------------------------------------------------------------------

patch_caelestia_cli() {
    log "Patching Caelestia CLI recorder"

    local record_py
    record_py=$(python3 -c 'import caelestia.subcommands.record as m; print(m.__file__)' 2>/dev/null) ||
        {
            warn "Caelestia CLI not importable; skipping recorder patch."
            return 0
        }

    # Installed system-wide by build_caelestia_ecosystem, so usually root-owned.
    local SUDO=""
    [[ -w "$record_py" ]] || SUDO="sudo"

    # Replacing the monitor name itself works whether upstream writes the
    # argument list on one line or several (it has done both).
    $SUDO python3 - "$record_py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if 'focused_monitor["name"]' in s:
    s = s.replace('focused_monitor["name"]', '"portal"')
    print('    recorder now uses portal capture')
elif '"portal"' in s:
    print('    recorder already uses portal capture')
else:
    print(f'    [warn] recorder code has changed upstream; check {p} by hand')
if '.mp4"' in s:
    s = s.replace('.mp4"', '.mkv"')
    print('    recordings now saved as .mkv')
p.write_text(s)
PY
}

# ---------------------------------------------------------------------------
# Personal config
# ---------------------------------------------------------------------------

restore_personal_config() {
    log "Restoring personal config from git"

    local tmp
    tmp=$(mktemp -d)
    git clone --depth 1 "$PERSONAL_CONFIG_REPO" "$tmp/config"
    # Drop .git first — otherwise a repo history lands in ~/.config/caelestia and
    # gets silently destroyed by the backup-and-replace on the next run.
    rm -rf "$tmp/config/.git"

    # The repo's home/ folder mirrors $HOME, for files that live outside
    # ~/.config/caelestia: home/.config/sunshine/start_vd.sh is installed as
    # ~/.config/sunshine/start_vd.sh, home/.local/bin/x as ~/.local/bin/x, etc.
    # Everything else in the repo is Caelestia config.
    if [[ -d "$tmp/config/home" ]]; then
        find "$tmp/config/home" -type f \( -name '*.sh' -o -path '*/.local/bin/*' \) \
            -exec chmod +x {} +
        cp -a "$tmp/config/home/." "$HOME/"
        info "installed from home/: $(cd "$tmp/config/home" && find . -type f | sed 's|^\./|~/|' | paste -sd ' ')"
        rm -rf "$tmp/config/home"
    fi

    mkdir -p "$HOME/.config/caelestia"
    cp -a "$tmp/config/." "$HOME/.config/caelestia/"
    rm -rf "$tmp"

    # start.sh drives the whole session start: it waits for Hyprland's IPC
    # socket, exports the Wayland environment into DBus and systemd, binds
    # graphical-session.target (which is what lets Sunshine start), and then
    # launches the shell. If it isn't here, the desktop comes up with no shell.
    local start_sh="$HOME/.config/caelestia/start.sh"
    [[ -f "$start_sh" ]] || die "start.sh missing from $PERSONAL_CONFIG_REPO — commit it before rerunning."
    chmod +x "$start_sh"
    info "start.sh present and executable"

    # Thunar's daemon should start before anything else can claim the
    # org.freedesktop.FileManager1 name (see configure_desktop).
    if ! grep -q 'ipc call lock lock' "$start_sh"; then
        warn "start.sh doesn't lock the session on startup. To start locked, drop the"
        warn "'exec' from the Caelestia line and end the file with, then commit it:"
        warn "    qs -c caelestia ipc call lock lock"
        warn "    sleep 1"
        warn '    while [ "$(qs -c caelestia ipc call lock isLocked)" = "true" ]; do sleep 1; done'
        warn "    caelestia wallpaper -r"
    fi
    # Leftovers from debugging the keyring prompt.
    if grep -qE 'dbus-monitor|bus-names\.log|keyring-check' "$start_sh"; then
        warn "start.sh still contains temporary debugging lines (dbus-monitor,"
        warn "bus-names.log or keyring-check); remove them from your repo copy."
    fi
    if ! grep -q 'thunar --daemon' "$start_sh"; then
        warn "start.sh doesn't start 'thunar --daemon'. Add this line before the"
        warn "exec that launches Caelestia, then commit it to your config repo:"
        warn "    thunar --daemon &"
    fi

    # A wallpaper change reloads Hyprland's config (Caelestia rewrites
    # hypr/scheme/current.lua), which wipes the monitor layout start_vd.sh set
    # with hyprctl eval. hypr-user.lua has to re-apply start_vd.sh's state file.
    local user_lua="$HOME/.config/caelestia/hypr-user.lua"
    if [[ -f "$user_lua" ]] && ! grep -q 'sunshine_vd.lua' "$user_lua"; then
        warn "hypr-user.lua doesn't re-apply the Sunshine virtual display on reload;"
        warn "a wallpaper change during a stream will turn the monitors back on."
        warn "Append the sunshine_vd.lua block to it and commit it to your repo."
    fi
}

# ---------------------------------------------------------------------------
# Point Hyprland's autostart at start.sh
# ---------------------------------------------------------------------------

patch_execs_lua() {
    log "Pointing execs.lua at start.sh"

    python3 - <<'PY'
import os, re, sys

candidates = [
    os.path.expanduser("~/.config/hypr/hyprland/execs.lua"),
    os.path.expanduser("~/.config/caelestia/hyprland/execs.lua"),
]
path = next((p for p in candidates if os.path.exists(p)), None)
if path is None:
    sys.exit("ERROR: execs.lua not found. Looked in:\n  " + "\n  ".join(candidates))

new_cmd = 'hl.exec_cmd("bash ~/.config/caelestia/start.sh")'

with open(path) as f:
    lines = f.readlines()

if any("start.sh" in l for l in lines):
    print(f"    {path} already launches start.sh")
    sys.exit(0)

replaced = False
out = []
for line in lines:
    if not replaced and "hl.exec_cmd" in line and "caelestia" in line and "shell" in line:
        indent = re.match(r"\s*", line).group(0)
        out.append(f"{indent}{new_cmd}\n")
        replaced = True
    else:
        out.append(line)

if not replaced:
    sys.exit(f"ERROR: no Caelestia launch line found in {path}. "
             "Upstream dotfiles may have changed — patch this by hand.")

with open(path, "w") as f:
    f.writelines(out)

print(f"    rewrote Caelestia launch line in {path}")
PY
}

# ---------------------------------------------------------------------------
# systemd user units
# ---------------------------------------------------------------------------

install_user_units() {
    log "Installing systemd user units"

    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir" "$HOME/.local/bin"

    # --- hyprland-session.target -------------------------------------------
    # Hyprland only ships this when built with systemd support. Without it,
    # graphical-session.target is never reached and nothing WantedBy it (most
    # importantly Sunshine) ever starts. start.sh activates this target.
    if systemctl --user cat hyprland-session.target >/dev/null 2>&1; then
        info "hyprland-session.target provided by Hyprland"
    else
        info "hyprland-session.target missing; installing a local fallback"
        cat >"$unit_dir/hyprland-session.target" <<'EOF'
[Unit]
Description=Hyprland session
Documentation=man:systemd.special(7)
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
EOF
    fi

    # --- leftover wallpaper timer -------------------------------------------
    # Earlier versions of this script installed caelestia-refresh.timer, which
    # changed the wallpaper every 30 seconds. Remove it if it's still around.
    systemctl --user disable --now caelestia-refresh.timer 2>/dev/null || true
    rm -f "$unit_dir/caelestia-refresh.timer" "$unit_dir/caelestia-refresh.service" \
        "$HOME/.local/bin/caelestia-refresh"

    systemctl --user daemon-reload

    # --- Sunshine -----------------------------------------------------------
    if systemctl --user list-unit-files sunshine.service >/dev/null 2>&1 &&
        systemctl --user cat sunshine.service >/dev/null 2>&1; then
        systemctl --user enable sunshine.service
        info "sunshine.service enabled (starts with graphical-session.target)"
    else
        info "Sunshine not installed; skipping. Enable later with:"
        info "  systemctl --user enable sunshine.service"
    fi

    # --- leftovers from earlier hyprbuntu runs ------------------------------
    # Both are WantedBy=graphical-session.target, so start.sh starting the
    # session target starts them too. See the note in run_hyprbuntu().
    local unit
    for unit in hypridle.service hyprpaper.service; do
        if systemctl --user cat "$unit" >/dev/null 2>&1; then
            systemctl --user disable --now "$unit" 2>/dev/null || true
            info "disabled $unit (Caelestia handles this)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Portal preference
# ---------------------------------------------------------------------------

configure_portals() {
    log "Configuring xdg-desktop-portal backends"

    mkdir -p "$HOME/.config/xdg-desktop-portal"
    # hyprland first for screen capture, gtk as fallback for file pickers.
    printf '[preferred]\ndefault=hyprland;gtk\n' \
        >"$HOME/.config/xdg-desktop-portal/hyprland-portals.conf"
}

# ---------------------------------------------------------------------------
# Sunshine
#
# Recent Sunshine releases default to XDG Portal capture, which pops a monitor
# picker on every start and fed NVENC frames it couldn't encode
# ("Failed locking bitstream buffer"). wlroots screencopy works on Hyprland
# and needs no picker.
# ---------------------------------------------------------------------------

configure_sunshine() {
    log "Configuring Sunshine"

    if ! command -v sunshine >/dev/null 2>&1; then
        info "Sunshine not installed; skipping."
        return 0
    fi

    local conf="$HOME/.config/sunshine/sunshine.conf"
    mkdir -p "$(dirname "$conf")"
    touch "$conf"
    if grep -q '^capture *=' "$conf"; then
        sed -i 's/^capture *=.*/capture = wlr/' "$conf"
    else
        echo "capture = wlr" >>"$conf"
    fi
    info "capture = wlr set in $conf"
}

# ---------------------------------------------------------------------------
# Desktop integration
# ---------------------------------------------------------------------------

configure_desktop() {
    log "Configuring desktop integration"

    # --- GTK theme ------------------------------------------------------------
    # Caelestia writes its colours into ~/.config/gtk-{3,4}.0/gtk.css using
    # adw-gtk3's colour names, then sets the GTK theme to adw-gtk3-dark. Without
    # adw-gtk3 installed, GTK falls back to light Adwaita: dark backgrounds from
    # Caelestia's CSS with black text from Adwaita (unreadable Thunar).
    if [[ -d "$HOME/.local/share/themes/adw-gtk3-dark" ]]; then
        info "adw-gtk3 already installed"
    else
        install_adw_gtk3 "$ADW_GTK3_VERSION"
    fi

    # hyprbuntu (THEME_PREF=dark) leaves two things that fight Caelestia:
    #  - GTK_THEME=Adwaita:dark in the uwsm environment, which overrides every
    #    other theme setting when the session is started through uwsm;
    #  - gtk-theme-name=Adwaita:dark in settings.ini, which isn't a valid theme
    #    name there (the :dark suffix only works in GTK_THEME).
    local uwsm_env="$HOME/.config/uwsm/env"
    if [[ -f "$uwsm_env" ]] && grep -q '^export GTK_THEME=' "$uwsm_env"; then
        sed -i '/^export GTK_THEME=/d' "$uwsm_env"
        info "removed GTK_THEME from $uwsm_env"
    fi
    local ini
    for ini in "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"; do
        [[ -f "$ini" ]] || continue
        sed -i 's/^gtk-theme-name=.*/gtk-theme-name=adw-gtk3-dark/' "$ini"
    done
    # GTK 4 / libadwaita ignores this key and warns about it on every launch;
    # the colour-scheme preference (set by Caelestia) replaces it.
    if [[ -f "$HOME/.config/gtk-4.0/settings.ini" ]]; then
        sed -i '/^gtk-application-prefer-dark-theme=/d' "$HOME/.config/gtk-4.0/settings.ini"
    fi

    gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' ||
        warn "gsettings unavailable (not in a session?); Caelestia will set the theme on its next scheme change"

    # --- Thunar as the file manager ----------------------------------------------
    # Folders opened via xdg-open follow the inode/directory default. Apps like
    # Chrome ("Show in folder") instead ask D-Bus for org.freedesktop.FileManager1,
    # which Nautilus claims by default; a user-level service file points D-Bus at
    # Thunar instead. start.sh also starts Thunar's daemon so it owns the name
    # before anything else can.
    xdg-mime default thunar.desktop inode/directory ||
        warn "xdg-mime failed; set Thunar as the folder handler by hand"

    local dbus_dir="$HOME/.local/share/dbus-1/services"
    mkdir -p "$dbus_dir"
    cat >"$dbus_dir/org.freedesktop.FileManager1.service" <<EOF
[D-BUS Service]
Name=org.freedesktop.FileManager1
Exec=$(command -v thunar || echo /usr/bin/thunar) --daemon
EOF
    info "Thunar registered as org.freedesktop.FileManager1"

    # GTK 3 only reads gtk.css when a process starts, so the long-running Thunar
    # daemon would keep the colours it started with. Quit it whenever Caelestia
    # rewrites gtk.css; the next folder open starts a fresh one.
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    cat >"$unit_dir/thunar-theme-reload.path" <<'EOF'
[Unit]
Description=Watch GTK colours for Caelestia theme changes

[Path]
PathChanged=%h/.config/gtk-3.0/gtk.css

[Install]
WantedBy=default.target
EOF
    cat >"$unit_dir/thunar-theme-reload.service" <<'EOF'
[Unit]
Description=Restart Thunar so it picks up new GTK colours

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'pgrep -x thunar >/dev/null && /usr/bin/thunar -q; exit 0'
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now thunar-theme-reload.path
    info "thunar-theme-reload.path enabled"

    # --- default browser -----------------------------------------------------------
    # xdg-mime instead of xdg-settings: xdg-settings shells out to coreutils,
    # which get SIGSYS'd when it runs inside Chrome's sandbox (uutils + seccomp).
    if [[ -f /usr/share/applications/google-chrome.desktop ]]; then
        xdg-mime default google-chrome.desktop x-scheme-handler/http x-scheme-handler/https text/html ||
            warn "xdg-mime failed; set the default browser by hand"
        info "Chrome set as default browser"
    else
        info "Chrome not installed; leaving the default browser alone"
    fi

    # --- Chrome follows the wallpaper colours -------------------------------------
    # On every colour scheme change, Caelestia writes Chrome's theme colour into a
    # managed policy file with `sudo -n tee`, which silently fails without a
    # passwordless rule -- so the colour stayed frozen at whatever it was when the
    # file was first written. Allow exactly that one command without a password.
    # Caveat: Chrome policies can do more than colours (e.g. force extensions), so
    # anything running as this user can now change them.
    if command -v google-chrome-stable >/dev/null 2>&1; then
        sudo mkdir -p /etc/opt/chrome/policies/managed
        local rule_tmp
        rule_tmp=$(mktemp)
        echo "$USER ALL=(root) NOPASSWD: /usr/bin/tee /etc/opt/chrome/policies/managed/caelestia.json" >"$rule_tmp"
        if sudo visudo -cf "$rule_tmp" >/dev/null; then
            sudo install -m 0440 -o root -g root "$rule_tmp" /etc/sudoers.d/caelestia-chrome
            info "Chrome theme colour can now follow the wallpaper"
        else
            warn "sudoers rule for Chrome theming failed validation; skipped"
        fi
        rm -f "$rule_tmp"
    fi

    # --- wine-open-url --------------------------------------------------------------
    # For Proton/Wine launchers (LLauncher): set BROWSER to this in the launcher's
    # environment. It asks systemd to start Chrome, so Chrome doesn't inherit the
    # game's seccomp filter -- the reason xdg-open fell back to Firefox.
    mkdir -p "$HOME/.local/bin"
    printf '%s\n' '#!/bin/sh' 'exec systemd-run --user --quiet google-chrome "$@"' \
        >"$HOME/.local/bin/wine-open-url"
    chmod +x "$HOME/.local/bin/wine-open-url"
    info "installed ~/.local/bin/wine-open-url"
}

# ---------------------------------------------------------------------------
# System-level fixes
# ---------------------------------------------------------------------------

apply_system_fixes() {
    log "Applying system-level fixes"

    # --- 1. power-profiles-daemon ------------------------------------------
    # See the note above install_base_packages(). Masking makes the portal's
    # DBus activation fail fast instead of blocking the shell for 8 seconds.
    # This is a desktop; PPD only manages laptop power profiles.
    if [[ "$(systemctl is-enabled power-profiles-daemon.service 2>/dev/null)" != "masked" ]]; then
        sudo systemctl mask power-profiles-daemon.service
        info "masked power-profiles-daemon.service"
    else
        info "power-profiles-daemon.service already masked"
    fi

    # --- 2. plymouth --------------------------------------------------------
    # The root cause of the above: plymouth-quit-wait.service holds
    # multi-user.target open for ~11s, so any system service a
    # early-autostarting app touches is stalled behind it. Dropping the splash
    # removes the barrier for everything, not just PPD.
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*\bsplash\b' /etc/default/grub; then
        sudo cp /etc/default/grub "/etc/default/grub.bak.$(date +%Y%m%d_%H%M%S)"
        sudo sed -i \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bsplash\b//g' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/  \+/ /g' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/" /"/' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/ "/"/' \
            /etc/default/grub
        sudo update-grub
        info "removed 'splash' from GRUB_CMDLINE_LINUX_DEFAULT"
    else
        info "no 'splash' in GRUB_CMDLINE_LINUX_DEFAULT"
    fi

    # --- 3. stale autostart entries ----------------------------------------
    # AppImage .desktop files point at /tmp mount paths that vanish on reboot,
    # producing a generator error on every boot.
    local autostart="$HOME/.config/autostart"
    if [[ -d "$autostart" ]]; then
        local f exec_line bin
        for f in "$autostart"/*.desktop; do
            [[ -e "$f" ]] || continue
            exec_line=$(grep -m1 '^Exec=' "$f" 2>/dev/null || true)
            [[ -n "$exec_line" ]] || continue
            bin=$(printf '%s' "${exec_line#Exec=}" | awk '{print $1}')
            if [[ "$bin" == /* && ! -e "$bin" ]]; then
                warn "autostart entry $(basename "$f") points at missing $bin"
                info "  remove it with: rm '$f'"
            fi
        done
    fi

    # --- 4. apport ----------------------------------------------------------
    # Ubuntu's Rust coreutils (uutils) get killed with SIGSYS when run inside
    # another app's seccomp sandbox (Chrome's xdg-settings, Proton games), and
    # apport pops a crash dialog for every one. They're harmless; the dialogs
    # aren't. Crash reporting isn't useful on a machine this heavily customised.
    if systemctl is-enabled apport.service >/dev/null 2>&1; then
        sudo systemctl disable --now apport.service
        info "disabled apport.service"
    fi
    echo "enabled=0" | sudo tee /etc/default/apport >/dev/null
    gsettings set com.ubuntu.update-notifier show-apport-crashes false 2>/dev/null || true
    sudo rm -f /var/crash/*.crash
}

# ---------------------------------------------------------------------------
# NVIDIA kernel module check
#
# Ubuntu ships the NVIDIA driver as prebuilt, per-kernel module packages. If a
# kernel update lands before its matching module package, the next boot has no
# GPU driver: all monitors vanish and Hyprland falls back to a 1024x768
# "Unknown-1" output. `apt full-upgrade` (not `upgrade`) installs the matching
# modules once they're published.
# ---------------------------------------------------------------------------

check_nvidia_modules() {
    log "Checking NVIDIA modules for installed kernels"

    if ! dpkg -l 'nvidia-driver-*' 2>/dev/null | grep -q '^ii'; then
        info "no NVIDIA driver package installed; skipping"
        return 0
    fi

    local newest
    newest=$(ls /lib/modules | sort -V | tail -1)
    if modinfo -k "$newest" nvidia >/dev/null 2>&1; then
        info "nvidia module present for newest kernel ($newest)"
    else
        warn "No nvidia module for kernel $newest -- booting it will leave you without"
        warn "a GPU driver. Run 'sudo apt update && sudo apt full-upgrade' before"
        warn "rebooting; if that doesn't add it, boot the previous kernel from GRUB."
    fi
}

# ---------------------------------------------------------------------------
# Release downloads: adw-gtk3 and Sunshine
# ---------------------------------------------------------------------------

# Tag of a GitHub repo's latest release. Follows the /releases/latest
# redirect, so no API token or rate limit is involved.
latest_github_release() { # OWNER/REPO
    local url
    url=$(curl -fsSL -o /dev/null -w '%{url_effective}' --proto '=https' --tlsv1.2 \
        "https://github.com/$1/releases/latest") || return 1
    [[ "$url" == */releases/tag/* ]] || return 1
    printf '%s\n' "${url##*/releases/tag/}"
}

# The SHA-256 GitHub publishes for a release asset; empty if unavailable.
github_asset_sha256() { # OWNER/REPO TAG ASSET
    curl -fsSL --proto '=https' --tlsv1.2 \
        "https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null |
        ASSET="$3" python3 -c '
import json, os, sys
for a in json.load(sys.stdin).get("assets", []):
    d = str(a.get("digest") or "")
    if a.get("name") == os.environ["ASSET"] and d.startswith("sha256:"):
        print(d[7:])
' 2>/dev/null || true
}

# The GTK theme Caelestia's colours are written for. Unpacked to a scratch
# directory first, so a bad download never removes the working theme.
install_adw_gtk3() { # TAG
    local tag=$1 themes="$HOME/.local/share/themes" tmp d
    tmp=$(mktemp -d)
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/adw.tar.xz" \
        "https://github.com/lassekongo83/adw-gtk3/releases/download/${tag}/adw-gtk3${tag}.tar.xz" ||
        {
            rm -rf "$tmp"
            die "Could not download adw-gtk3 $tag"
        }
    mkdir "$tmp/x"
    tar xJf "$tmp/adw.tar.xz" -C "$tmp/x"
    [[ -d "$tmp/x/adw-gtk3-dark" ]] ||
        {
            rm -rf "$tmp"
            die "adw-gtk3 $tag archive doesn't contain adw-gtk3-dark"
        }
    mkdir -p "$themes"
    for d in "$tmp/x"/*/; do
        d=${d%/}
        rm -rf "${themes:?}/${d##*/}"
        mv "$d" "$themes/"
    done
    rm -rf "$tmp"
    state_set adw-gtk3 "$tag"
    info "installed adw-gtk3 $tag"
}

# Sunshine comes from its GitHub release .deb, which never updates itself.
update_sunshine() { # TAG
    local tag=$1 os arch deb tmp want sum
    log "Updating Sunshine to $tag"
    os=$(. /etc/os-release && printf '%s' "$VERSION_ID")
    arch=$(dpkg --print-architecture)
    deb="sunshine_${tag#v}-1+ubuntu${os}_${arch}.deb"
    tmp=$(mktemp -d)
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/$deb" \
        "https://github.com/LizardByte/Sunshine/releases/download/${tag}/${deb}" ||
        {
            rm -rf "$tmp"
            die "Sunshine $tag has no $deb"
        }

    want=$(github_asset_sha256 LizardByte/Sunshine "$tag" "$deb")
    if [[ -n "$want" ]]; then
        sum=$(sha256sum "$tmp/$deb" | cut -d ' ' -f 1)
        [[ "$sum" == "$want" ]] || {
            rm -rf "$tmp"
            die "Checksum mismatch for $deb"
        }
        info "checksum matches GitHub's"
    else
        warn "GitHub gave no checksum for $deb; installing on the HTTPS download alone"
    fi
    [[ "$(dpkg-deb -f "$tmp/$deb" Package)" == sunshine ]] ||
        {
            rm -rf "$tmp"
            die "$deb isn't the sunshine package"
        }

    # Readable by apt's sandbox user, which avoids an "unsandboxed" notice.
    chmod 755 "$tmp"
    chmod 644 "$tmp/$deb"
    sudo apt-get install -y "$tmp/$deb"
    rm -rf "$tmp"

    # Restarting Sunshine ends any stream in progress -- possibly this one.
    if hyprctl monitors 2>/dev/null | grep -q '^Monitor sunshine_vd'; then
        warn "A stream is running; restart Sunshine afterwards: systemctl --user restart sunshine"
    else
        systemctl --user restart sunshine.service || warn "Couldn't restart sunshine.service"
    fi
}

# ---------------------------------------------------------------------------
# Updates: ./hypr-setup.sh update [component...]
#
# Checks every component against upstream, shows what would change, and asks
# before doing anything. Then, in order:
#   system      apt full-upgrade (kernel and NVIDIA modules move together)
#   hyprland    hyprbuntu: Hyprland, its libraries and the portal, at their
#               latest releases (hyprbuntu only rebuilds what changed)
#   quickshell, libcava, caelestia (plugin + QML), cli
#               all built first, then installed together, with the shell
#               stopped while its files change and restarted afterwards
#   gsr, sunshine, theme
#               each on its own, so one failing doesn't stop the others
# Config files are never touched (update-config.sh does those), components
# already up to date are skipped, and anything that failed is retried on the
# next run.
# ---------------------------------------------------------------------------

UPDATE_COMPONENTS=(system hyprland quickshell libcava caelestia cli gsr sunshine theme)

_in() {
    local x=$1
    shift
    [[ " $* " == *" $x "* ]]
}

stop_shell() {
    [[ "$SHELL_STOPPED" == 1 ]] && return 0
    qs -c caelestia kill >/dev/null 2>&1 || true
    SHELL_STOPPED=1
    info "Caelestia shell stopped while its files are replaced"
}

start_shell() {
    SHELL_STOPPED=0
    local preload=/usr/lib/x86_64-linux-gnu/libfftw3.so.3
    # 9>&-: the shell outlives this script and mustn't hold update()'s lock.
    if (
        cd "$HOME/.config/quickshell/caelestia" || exit 1
        if [[ -e "$preload" ]]; then export LD_PRELOAD="$preload"; fi
        caelestia shell -d
    ) >/dev/null 2>&1 9>&-; then
        info "Caelestia shell restarted"
    else
        warn "Couldn't restart the Caelestia shell; log out and back in."
    fi
}

# One step as its own process: if it fails, that's reported and the update
# carries on (the step is retried next run).
run_step() {
    HYPR_SETUP_CHILD=1 bash "$SELF" --step "$@" 9>&-
}

update() {
    local c
    for c in "$@"; do
        _in "$c" "${UPDATE_COMPONENTS[@]}" ||
            die "Unknown component '$c'. Choose from: ${UPDATE_COMPONENTS[*]}"
    done
    local explicit=$#
    local -a want=("$@")
    ((explicit)) || want=("${UPDATE_COMPONENTS[@]}")

    preflight
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || die "Another hypr-setup.sh run is in progress."

    # --- what's out of date -------------------------------------------------
    log "Checking for updates"
    local -a plan=() todo=()
    local -A new=()
    local have latest tag

    if _in system "${want[@]}"; then
        sudo apt-get update -qq
        local sim counts removals
        sim=$(apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null || true)
        counts=$(grep -m 1 -E '^[0-9]+ upgraded' <<<"$sim" || true)
        removals=$(awk '/^Remv / { print $2 }' <<<"$sim" | paste -sd ' ' || true)
        if [[ -z "$counts" || "$counts" == "0 upgraded, 0 newly installed, 0 to remove"* ]]; then
            plan+=("System packages|up to date")
        else
            todo+=(system)
            plan+=("System packages|${counts%.}")
            if [[ -n "$removals" ]]; then plan+=("  WILL REMOVE|$removals"); fi
        fi
    fi

    if _in hyprland "${want[@]}"; then
        have=$(hyprctl version -j 2>/dev/null |
            python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag", ""))' 2>/dev/null || true)
        have=${have%%-*}
        latest=$(latest_tag https://github.com/hyprwm/Hyprland.git)
        if [[ -z "$latest" ]]; then
            plan+=("Hyprland|can't reach GitHub; skipped")
        elif ((explicit)) || [[ "$have" != "$latest" ]]; then
            todo+=(hyprland)
            plan+=("Hyprland|${have:-unknown} -> $latest (with its libraries and portal, via hyprbuntu)")
        else
            plan+=("Hyprland|$have up to date")
        fi
    fi

    _plan_git() { # COMPONENT LABEL URL REF STATE-KEY
        local cur target
        cur=$(state_get "$5")
        if ! target=$(resolve_ref "$3" "$4"); then
            plan+=("$2|can't resolve $4 from $3; skipped")
            return 0
        fi
        new[$1]=$target
        if [[ "$cur" == "$target" ]]; then
            plan+=("$2|$(short "$cur") up to date")
        else
            todo+=("$1")
            plan+=("$2|$(short "$cur") -> $(short "$target")")
        fi
    }
    if _in quickshell "${want[@]}"; then
        _plan_git quickshell "Quickshell" "$QUICKSHELL_URL" "$QUICKSHELL_REF" quickshell
    fi
    if _in libcava "${want[@]}"; then
        _plan_git libcava "libcava" "$LIBCAVA_URL" "$LIBCAVA_REF" libcava
    fi
    if _in caelestia "${want[@]}"; then
        _plan_git caelestia "Caelestia shell" "$CAELESTIA_SHELL_URL" "$CAELESTIA_SHELL_REF" caelestia-shell
    fi
    if _in cli "${want[@]}"; then
        _plan_git cli "Caelestia CLI" "$CAELESTIA_CLI_URL" "$CAELESTIA_CLI_REF" caelestia-cli
    fi
    if _in gsr "${want[@]}"; then
        _plan_git gsr "gpu-screen-recorder" "$GSR_URL" HEAD gsr
    fi
    # The shell plugin links libcava, so a new libcava means rebuilding it.
    if _in libcava "${todo[@]}" && ! _in caelestia "${todo[@]}"; then
        new[caelestia]=$(state_get caelestia-shell)
        if [[ -z "${new[caelestia]}" ]]; then
            new[caelestia]=$(resolve_ref "$CAELESTIA_SHELL_URL" "$CAELESTIA_SHELL_REF") ||
                die "Can't resolve Caelestia shell $CAELESTIA_SHELL_REF"
        fi
        todo+=(caelestia)
        plan+=("Caelestia shell|rebuilt against the new libcava")
    fi

    if _in sunshine "${want[@]}"; then
        have=$(dpkg-query -W -f='${Version}' sunshine 2>/dev/null || true)
        if [[ -z "$have" ]]; then
            plan+=("Sunshine|not installed from a .deb; skipped")
        elif ! tag=$(latest_github_release LizardByte/Sunshine); then
            plan+=("Sunshine|can't reach GitHub; skipped")
        else
            latest="${tag#v}-1+ubuntu$(. /etc/os-release && printf '%s' "$VERSION_ID")"
            if dpkg --compare-versions "$latest" gt "$have"; then
                todo+=(sunshine)
                new[sunshine]=$tag
                plan+=("Sunshine|$have -> $latest")
            else
                plan+=("Sunshine|$have up to date")
            fi
        fi
    fi

    if _in theme "${want[@]}"; then
        have=$(state_get adw-gtk3)
        if ! tag=$(latest_github_release lassekongo83/adw-gtk3); then
            plan+=("adw-gtk3 theme|can't reach GitHub; skipped")
        elif [[ "$have" == "$tag" ]]; then
            plan+=("adw-gtk3 theme|$have up to date")
        else
            todo+=(theme)
            new[theme]=$tag
            plan+=("adw-gtk3 theme|${have:-unknown} -> $tag")
        fi
    fi

    echo
    local line
    for line in "${plan[@]}"; do
        printf '    %-20s %s\n' "${line%%|*}" "${line#*|}"
    done
    echo

    if ((${#todo[@]} == 0)); then
        log "Everything is up to date"
        return 0
    fi
    info "Config files aren't touched. Log out or reboot when it's done."
    if [[ "$UPDATE_YES" != 1 ]]; then
        local answer=""
        read -rp "Update ${todo[*]}? [y/N] " answer || true
        if [[ "$answer" != [yY]* ]]; then
            info "Nothing changed."
            return 0
        fi
    fi

    # --- do it ------------------------------------------------------------------
    local -a ok=() failed=()

    if _in system "${todo[@]}"; then
        log "Upgrading system packages"
        # confold: keep your edited config files (GRUB, apport...) as they are.
        sudo apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
        ok+=(system)
        check_nvidia_modules
    fi

    if _in hyprland "${todo[@]}"; then
        if run_step run_hyprbuntu; then ok+=(hyprland); else failed+=(hyprland); fi
    fi

    local -a builds=()
    for c in quickshell libcava caelestia cli; do
        if _in "$c" "${todo[@]}"; then builds+=("$c"); fi
    done

    if ((${#builds[@]})); then
        command -v meson >/dev/null || sudo apt-get install -y meson
        BUILD_DIR=$(mktemp -d -p "$HOME" .hypr-update.XXXXXX)
        local src="$BUILD_DIR" qml="$HOME/.config/quickshell/caelestia"

        # Build everything first: if any build fails, nothing has changed yet.
        if _in quickshell "${builds[@]}"; then
            fetch_at "$QUICKSHELL_URL" "${new[quickshell]}" "$src/quickshell"
            build_quickshell "$src/quickshell" "${new[quickshell]}"
        fi
        if _in libcava "${builds[@]}"; then
            fetch_at "$LIBCAVA_URL" "${new[libcava]}" "$src/libcava"
            build_libcava "$src/libcava"
            # The one early install: the plugin compiles against libcava's
            # headers. If a later build fails, the shell comes back on the old
            # plugin.
            stop_shell
            install_libcava "$src/libcava" "${new[libcava]}"
        fi
        if _in caelestia "${builds[@]}"; then
            fetch_at "$CAELESTIA_SHELL_URL" "${new[caelestia]}" "$src/caelestia-shell"
            build_caelestia_plugin "$src/caelestia-shell" "${new[caelestia]}"
            # Download the matching QML now, so switching to it later can't
            # fail halfway on a network problem.
            if [[ -d "$qml/.git" ]]; then
                git -C "$qml" fetch -q --depth 1 "$CAELESTIA_SHELL_URL" "${new[caelestia]}"
            fi
        fi
        if _in cli "${builds[@]}"; then
            fetch_at "$CAELESTIA_CLI_URL" "${new[cli]}" "$src/caelestia-cli"
            build_caelestia_cli "$src/caelestia-cli"
        fi

        # Everything built; install. cleanup() restarts the shell if anything
        # below fails.
        if _in quickshell "${builds[@]}" || _in caelestia "${builds[@]}"; then
            stop_shell
        fi
        if _in quickshell "${builds[@]}"; then
            install_quickshell "$src/quickshell" "${new[quickshell]}"
            ok+=(quickshell)
        fi
        if _in libcava "${builds[@]}"; then ok+=(libcava); fi
        if _in caelestia "${builds[@]}"; then
            install_caelestia_plugin "$src/caelestia-shell"
            sync_shell_qml "${new[caelestia]}"
            patch_caelestia_qml
            state_set caelestia-shell "${new[caelestia]}"
            ok+=(caelestia)
        fi
        if _in cli "${builds[@]}"; then
            install_caelestia_cli "$src/caelestia-cli" "${new[cli]}"
            patch_caelestia_cli
            ok+=(cli)
        fi

        rm -rf "$BUILD_DIR"
        BUILD_DIR=""
        if [[ "$SHELL_STOPPED" == 1 ]]; then start_shell; fi
    fi

    if _in gsr "${todo[@]}"; then
        if run_step build_gpu_screen_recorder; then ok+=(gsr); else failed+=(gsr); fi
    fi
    if _in sunshine "${todo[@]}"; then
        if run_step update_sunshine "${new[sunshine]}"; then ok+=(sunshine); else failed+=(sunshine); fi
    fi
    if _in theme "${todo[@]}"; then
        if run_step install_adw_gtk3 "${new[theme]}"; then ok+=(theme); else failed+=(theme); fi
    fi

    log "Update finished"
    if ((${#ok[@]})); then info "Updated: ${ok[*]}"; fi
    if ((${#failed[@]})); then
        warn "Failed: ${failed[*]}. Rerun './hypr-setup.sh update' to retry; details in $LOG_FILE"
    fi
    if _in system "${ok[@]}" || _in hyprland "${ok[@]}"; then
        info "Reboot to start the new kernel, drivers and Hyprland."
    fi
    info "Your config repo isn't part of this; run update-config.sh for that."
    return 0
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    log "Done"

    cat <<EOF

Setup complete. Reboot, then verify:

  systemctl --user status graphical-session.target
  systemctl --user status sunshine.service
  systemctl is-enabled power-profiles-daemon.service     # expect: masked
  systemctl --user is-active hypridle hyprpaper          # expect: inactive
  gsettings get org.gnome.desktop.interface gtk-theme    # expect: 'adw-gtk3-dark'
  busctl --user status org.freedesktop.FileManager1 | grep Comm   # expect: thunar
  grep capture ~/.config/sunshine/sunshine.conf          # expect: capture = wlr

If the shell does not appear, check in this order:

  cat ~/.config/caelestia/start.sh                       # exists, executable
  grep -n start.sh ~/.config/hypr/hyprland/execs.lua     # autostart wired up
  journalctl --user -b 0 -o short-precise | less

Full log of this run: $LOG_FILE

To update everything this installed later:  ./hypr-setup.sh update

Not handled here (kept in your config repo or set by hand):
  - start.sh should run 'thunar --daemon &' before launching Caelestia
  - Caelestia's idle timeouts (shell config): remove the suspend entry if this
    machine must stay reachable for Sunshine
  - LLauncher: environment variable BROWSER=$HOME/.local/bin/wine-open-url
  - Keep using 'sudo apt full-upgrade' rather than 'upgrade', so kernel and
    NVIDIA module updates land together

Known outstanding item: the LD_PRELOAD on libfftw3 in start.sh works around a
link-order problem in the Caelestia plugin build. Fixing the CMake link line
would let the launch command drop back to a plain 'caelestia shell -d'.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    case "${1:-}" in
    update)
        shift
        update "$@"
        return 0
        ;;
    --step) # internal: one step with arguments, started by run_step()
        shift
        declare -F "${1:-}" >/dev/null || die "Unknown step: ${1:-}"
        "$@"
        return 0
        ;;
    esac

    # Run individual steps by name, e.g. ./hypr-setup.sh patch_caelestia_qml
    if (($#)); then
        local step
        for step in "$@"; do
            declare -F "$step" >/dev/null || die "Unknown step: $step"
            "$step"
        done
        return 0
    fi

    preflight
    install_base_packages

    if [[ "$SKIP_HYPRBUNTU" == "1" ]]; then info "Skipping hyprbuntu"; else run_hyprbuntu; fi
    if [[ "$SKIP_CAELESTIA" == "1" ]]; then info "Skipping Caelestia build"; else build_caelestia_ecosystem; fi
    if [[ "$SKIP_PORTAL" == "1" ]]; then
        info "Skipping portal build"
    elif [[ "$SKIP_HYPRBUNTU" != "1" ]] && hyprbuntu_builds_portal; then
        info "xdg-desktop-portal-hyprland was built by hyprbuntu"
    else
        build_portal
    fi
    if [[ "$SKIP_GSR" == "1" ]]; then info "Skipping gpu-screen-recorder"; else build_gpu_screen_recorder; fi

    patch_caelestia_qml
    patch_caelestia_cli
    restore_personal_config
    patch_execs_lua
    install_user_units
    configure_portals
    configure_sunshine

    if [[ "$SKIP_DESKTOP" == "1" ]]; then info "Skipping desktop integration"; else configure_desktop; fi
    if [[ "$SKIP_SYSTEM_FIXES" == "1" ]]; then info "Skipping system fixes"; else apply_system_fixes; fi

    check_nvidia_modules
    print_summary
}

main "$@"
