#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source-path=SCRIPTDIR source=../zengolfer-bootstrap.sh
source "$repo/zengolfer-bootstrap.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

for fixture in 'debian 12 bookworm' 'debian 13 trixie' 'debian - forky' 'debian - sid' 'ubuntu 24.04 noble' 'ubuntu 26.04 resolute'; do
    read -r id version codename <<< "$fixture"
    printf 'ID=%s\nVERSION_ID="%s"\nVERSION_CODENAME=%s\n' "$id" "${version#-}" "$codename" > "$tmp/os"
    detect_release "$tmp/os"
done
printf 'ID=ubuntu\nVERSION_ID=22.04\n' > "$tmp/os"
if (detect_release "$tmp/os"); then exit 1; fi
(
    mkdir "$tmp/selection"
    cat > "$tmp/selection/apt-cache" <<'MOCK'
#!/bin/bash
printf '  Candidate: %s\n' "$(cat "$TEST_CACHE/$2")"
MOCK
    cat > "$tmp/selection/apt-get" <<'MOCK'
#!/bin/bash
[[ ! -e "$TEST_CACHE/$4-blocked" ]]
MOCK
    chmod +x "$tmp/selection/apt-cache" "$tmp/selection/apt-get"
    ln -s "$(command -v awk)" "$tmp/selection/awk"
    ln -s "$(command -v cat)" "$tmp/selection/cat"
    printf '1\n' > "$tmp/fastfetch"
    printf '1\n' > "$tmp/neofetch"
    [[ "$(TEST_CACHE="$tmp" PATH="$tmp/selection" select_fetch)" == fastfetch ]]
    : > "$tmp/fastfetch-blocked"
    [[ "$(TEST_CACHE="$tmp" PATH="$tmp/selection" select_fetch)" == neofetch ]]
    printf '(none)\n' > "$tmp/neofetch"
    [[ -z "$(TEST_CACHE="$tmp" PATH="$tmp/selection" select_fetch)" ]]
)
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/config with spaces"
export XDG_RUNTIME_DIR="$tmp/runtime" DISPLAY=:9 XDG_SESSION_TYPE=x11
export XDG_STATE_HOME="$tmp/state"
unset SSH_CONNECTION SSH_CLIENT SSH_TTY
mkdir -p "$XDG_CONFIG_HOME"/{autostart,conky} "$XDG_RUNTIME_DIR" "$tmp/bin" "$HOME/.ssh"
printf old > "$HOME/.zshrc"
printf older > "$HOME/.zshrc.pre-bootstrap"
printf old-desktop > "$XDG_CONFIG_HOME/autostart/zengolfer-conky-hud.desktop"
printf old-launcher > "$XDG_CONFIG_HOME/conky/start-hud.sh"
printf fixture > "$HOME/.ssh/dummy"
dotfiles_dir=$(realpath -e -- "${DOTFILES_DIR:-$repo/../dotfiles}")
deploy_configs
before=$(find "$HOME" -printf '%p %l\n' | sort)
deploy_configs
[[ "$before" == "$(find "$HOME" -printf '%p %l\n' | sort)" ]]
[[ "$(cat "$HOME/.zshrc.pre-bootstrap")" == older ]]
[[ "$(cat "$HOME/.zshrc.pre-bootstrap.1")" == old ]]
[[ "$(cat "$XDG_CONFIG_HOME/autostart/zengolfer-conky-hud.desktop.pre-bootstrap")" == old-desktop ]]
[[ "$(cat "$XDG_CONFIG_HOME/conky/start-hud.sh.pre-bootstrap")" == old-launcher ]]
[[ "$(readlink -f "$HOME/.conkyrc")" == "$dotfiles_dir/.config/conky/conky.conf" ]]
[[ "$(cat "$HOME/.ssh/dummy")" == fixture ]]

export PATH="$tmp/bin:$PATH" TEST_CAPTURE="$tmp/capture" TEST_VERSION=1.22.1
export TEST_GEOMETRY='1024/271x768/203+0+0'
export TEST_WORKAREA='0, 0, 1024, 768, 24, 30, 1000, 690'
cat > "$tmp/bin/xprop" <<'MOCK'
#!/bin/sh
printf '_NET_CURRENT_DESKTOP(CARDINAL) = 1\n_NET_WORKAREA(CARDINAL) = %s\n' "$TEST_WORKAREA"
MOCK
cat > "$tmp/bin/xrandr" <<'MOCK'
#!/bin/sh
printf 'Monitors: 1\n 0: +*Virtual-1 %s Virtual-1\n' "$TEST_GEOMETRY"
MOCK
cat > "$tmp/bin/xrdb" <<'MOCK'
#!/bin/sh
printf 'Xft.dpi: 96\n'
MOCK
cat > "$tmp/bin/sleep" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat > "$tmp/bin/conky" <<'MOCK'
#!/bin/sh
if test "$1" = --version; then
    printf 'conky %s compiled for Linux\n' "$TEST_VERSION"
else
    printf '%s\n' "$@" "$CONKY_HUD_WIDTH $CONKY_HUD_HEIGHT $CONKY_HUD_GAP_X $CONKY_HUD_GAP_Y $CONKY_HUD_SETTINGS" >> "$TEST_CAPTURE"
fi
MOCK
chmod +x "$tmp/bin/"*
launcher="$XDG_CONFIG_HOME/conky/start-hud.sh"
SSH_CONNECTION=fixture "$launcher"
XDG_SESSION_TYPE='tty' "$launcher"
DISPLAY='' "$launcher"
(
    flock -n 9
    "$launcher"
    :
) 9>>"$XDG_RUNTIME_DIR/zengolfer-conky-hud.lock"
[[ ! -e "$TEST_CAPTURE" ]]
"$launcher"
[[ "$(cat "$TEST_CAPTURE")" == "$(printf '%s\n' -c "$XDG_CONFIG_HOME/conky/conky.conf" '952 642 24 54 legacy')" ]]
: > "$TEST_CAPTURE"
XDG_SESSION_TYPE=wayland TEST_VERSION=1.25.0 TEST_GEOMETRY='1920/500x1080/281+0+0' TEST_WORKAREA='0, 0, 1920, 1080' "$launcher"
[[ "$(tail -n 1 "$TEST_CAPTURE")" == '1872 968 24 24 backend' ]]
: > "$TEST_CAPTURE"
TEST_VERSION=1.24.2 "$launcher"
[[ "$(tail -n 1 "$TEST_CAPTURE")" == '952 642 24 54 colour' ]]
printf 'Bootstrap and Conky launcher regression cases passed.\n'
