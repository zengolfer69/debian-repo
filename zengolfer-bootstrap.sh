#!/usr/bin/env bash
# zengolfer-bootstrap: canonical entry point
set -Eeuo pipefail

required_packages=(
    openssh-client openssh-server screen zsh git curl wget rsync ca-certificates
    gnupg gpgv python3 iproute2 conky-all x11-utils x11-xserver-utils procps
    build-essential devscripts debhelper dh-make
    fakeroot lintian dpkg-dev equivs quilt git-buildpackage pristine-tar pkg-config
    autoconf automake libtool cmake meson ninja-build make gcc g++ clang gdb strace
    libssl-dev libncurses-dev libreadline-dev zlib1g-dev libbz2-dev liblzma-dev
    libffi-dev libsqlite3-dev libxml2-dev libgtk-3-dev libgtk-4-dev libadwaita-1-dev
    libxslt1-dev apt-file
)
optional_packages=(ddate ltrace checkinstall fonts-hack)
personal_repo=https://zengolfer69.github.io/debian-repo
dotfiles_repo=git@github.com:zengolfer69/dotfiles.git

info() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

detect_release() {
    local release_file="${1:-/etc/os-release}" ID='' VERSION_ID='' VERSION_CODENAME='' PRETTY_NAME=''
    [[ -r "$release_file" ]] || die "Cannot read $release_file."
    # shellcheck disable=SC1090
    . "$release_file"
    case "$ID" in
        debian)
            if [[ "$VERSION_ID" =~ ^[0-9]+$ ]] && (( VERSION_ID < 12 )); then
                die "Debian 12 or newer is required."
            fi
            ;;
        ubuntu)
            if [[ ! "$VERSION_ID" =~ ^[0-9]+\.[0-9]+$ ]] ||
                ! dpkg --compare-versions "$VERSION_ID" ge 24.04; then
                die "Ubuntu 24.04 or newer is required."
            fi
            ;;
        *) die "Unsupported distribution: ${ID:-unknown}." ;;
    esac
    info "Detected ${PRETTY_NAME:-$ID} (version ${VERSION_ID:-rolling}, codename ${VERSION_CODENAME:-unspecified})."
}

has_candidate() {
    LC_ALL=C apt-cache policy "$1" |
        awk '$1 == "Candidate:" && $2 != "(none)" { found = 1 } END { exit !found }'
}

simulate_install() {
    local output
    if ! output=$(LC_ALL=C apt-get -s --no-remove install "$1" 2>&1); then
        [[ -z "$output" ]] || printf '%s\n' "$output" >&2
        return 1
    fi
    # APT simulations may report proposed removals even with --no-remove.
    if [[ "$output" == Remv\ * || "$output" == *$'\n'Remv\ * ]]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

select_fetch() {
    local package
    for package in fastfetch neofetch; do
        if command -v "$package" >/dev/null ||
            { has_candidate "$package" && simulate_install "$package" 2>/dev/null; }; then
            printf '%s\n' "$package"
            return
        fi
    done
}

is_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == 'install ok installed' ]]
}

install_optional() {
    local package="$1"
    if is_installed "$package"; then
        return
    fi
    if ! has_candidate "$package"; then
        warn "Skipping $package. APT has no candidate."
        return 1
    elif ! simulate_install "$package"; then
        warn "Skipping $package. APT cannot resolve an installation without removals."
        return 1
    elif ! sudo apt-get --no-remove --no-upgrade install -y "$package"; then
        warn "Installation of optional package $package failed."
        return 1
    fi
}

install_fetch() {
    local package
    package=$(select_fetch)
    if [[ -z "$package" ]]; then
        warn "Neither Fastfetch nor Neofetch is available."
    elif ! command -v "$package" >/dev/null && ! install_optional "$package"; then
        if [[ "$package" == fastfetch ]] && ! command -v neofetch >/dev/null; then
            install_optional neofetch || true
        fi
    fi
}

validate_signing_key() {
    local key="$1" keys
    local fingerprint=E8918D9EA194C7CF261F26E0BB9FFAF259BAB02E
    keys=$(gpg --batch --no-options --homedir "$scratch" --with-colons --show-keys "$key" |
        awk -F: '$1 == "pub" { primary = 1 } $1 == "fpr" && primary { print $10; primary = 0 }') ||
        die "Cannot read the personal archive signing key: $key"
    [[ "$keys" == "$fingerprint" ]] ||
        die "Unexpected signing key for the personal APT repository: $key"
}

atomic_install_apt_file() {
    local payload="$1" destination="$2"
    if [[ ! -L "$destination" && -f "$destination" ]] &&
        [[ "$(stat -c '%u:%g:%a' -- "$destination")" == 0:0:644 ]] &&
        cmp -s -- "$payload" "$destination"; then
        return
    fi
    # Root creates the temporary file in the destination directory. APT
    # ignores its name, and rename publishes only the completed file.
    sudo /bin/bash -s -- "$destination" "$payload" <<'ROOT_SCRIPT'
set -euo pipefail
destination=$1
payload=$2
if [[ -L "$destination" || ( -e "$destination" && ! -f "$destination" ) ]]; then
    printf 'Refusing to replace non-regular APT file: %s\n' "$destination" >&2
    exit 1
fi
staged=$(mktemp -- "$(dirname -- "$destination")/.$(basename -- "$destination").tmp.XXXXXXXX")
trap 'rm -f -- "$staged"' EXIT
install -o root -g root -m 0644 -- "$payload" "$staged"
cmp -- "$payload" "$staged"
mv -fT -- "$staged" "$destination"
ROOT_SCRIPT
}

install_personal_source() {
    local main="$1" parts="$2" keyring="$3"
    local source="$parts/zengolfer.list" plan signed_by
    local -a inspect=(python3 "$bootstrap_dir/lib/personal-apt-sources.py"
        "$main" "$parts" "$source" "$keyring" "$personal_repo")
    plan=$("${inspect[@]}") || return 1
    if [[ "$plan" != managed ]]; then
        signed_by=${plan#*$'\n'}
        if [[ "$signed_by" == '-----BEGIN PGP PUBLIC KEY BLOCK-----'* ]]; then
            printf '%s\n' "${signed_by//$'\n.\n'/$'\n\n'}" > "$scratch/existing-archive-key.asc"
            validate_signing_key "$scratch/existing-archive-key.asc"
        elif [[ "$signed_by" == /* && -f "$signed_by" && -r "$signed_by" ]]; then
            validate_signing_key "$signed_by"
        else
            die "Unsupported Signed-By in ${plan%%$'\n'*}. Use one readable keyring or an inline public key."
        fi
        info "Using the existing signed personal APT source at ${plan%%$'\n'*}."
        return
    fi

    cp -- "$bootstrap_dir/repo-key.gpg" "$scratch/repo-key.gpg" || return 1
    validate_signing_key "$scratch/repo-key.gpg"
    gpgv --keyring "$scratch/repo-key.gpg" "$bootstrap_dir/dists/stable/InRelease" ||
        die "The bundled signing key could not verify the personal archive Release."
    printf 'deb [arch=amd64 signed-by=%s] %s stable main\n' "$keyring" "$personal_repo" > "$scratch/zengolfer.list" ||
        return 1
    "${inspect[@]}" --validate-managed "$scratch/zengolfer.list" || return 1
    # Publish the validated key first. Both source versions use this keyring.
    atomic_install_apt_file "$scratch/repo-key.gpg" "$keyring" || return 1
    atomic_install_apt_file "$scratch/zengolfer.list" "$source"
}

install_desktop_apps() {
    if ! is_installed google-chrome-stable; then
        if has_candidate google-chrome-stable; then
            install_optional google-chrome-stable || true
        elif ! curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
            -o "$scratch/google-chrome.deb" ||
            ! sudo apt-get --no-remove --no-upgrade install -y "$scratch/google-chrome.deb"; then
            warn "Google Chrome installation failed."
        fi
    fi
    if ! is_installed discord; then
        if ! curl -fsSL 'https://discord.com/api/download?platform=linux&format=deb' \
            -o "$scratch/discord.deb" ||
            ! sudo apt-get --no-remove --no-upgrade install -y "$scratch/discord.deb"; then
            warn "Discord installation failed."
        fi
    fi
}

install_checkout() {
    local url="$1" target="$2" status upstream
    shift 2
    if [[ -e "$target/.git" ]]; then
        if ! status=$(git -C "$target" status --porcelain --untracked-files=all --ignore-submodules=none) ||
            [[ -n "$status" ]]; then
            warn "Skipping framework update for $target. The checkout has local changes or could not be inspected."
        elif [[ "$(git -C "$target" remote get-url origin 2>/dev/null)" != "$url" ]] ||
            ! upstream=$(git -C "$target" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null) ||
            [[ "$upstream" != refs/remotes/origin/* ]]; then
            warn "Skipping framework update for $target. The checkout does not track the expected upstream."
        elif ! git -C "$target" fetch --no-recurse-submodules origin ||
            ! git -C "$target" -c submodule.recurse=false merge --ff-only --no-autostash --no-overwrite-ignore "$upstream"; then
            warn "Skipping framework update for $target. A safe fast-forward was unavailable."
        fi
    elif [[ -e "$target" || -L "$target" ]]; then
        die "Existing path is not a Git checkout: $target"
    else
        git clone "$@" "$url" "$target"
    fi
}

link_config() {
    local source="$1" target="$2" backup suffix=0
    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
        return
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" || -L "$target" ]] || die "Cannot replace non-file path $target."
        backup="$target.pre-bootstrap"
        while [[ -e "$backup" || -L "$backup" ]]; do
            suffix=$((suffix + 1))
            backup="$target.pre-bootstrap.$suffix"
        done
        mv -T -- "$target" "$backup"
        info "Backed up $target to $backup"
        if ! ln -sT -- "$source" "$target"; then
            mv -nT -- "$backup" "$target"
            die "Could not link $target."
        fi
    else
        ln -sT -- "$source" "$target"
    fi
}

deploy_configs() {
    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}" file
    local autostart=zengolfer-conky-hud.desktop
    local -a sources=(.zshrc .p10k.zsh .config/conky/conky.conf
        .config/conky/start-hud.sh ".config/autostart/$autostart")
    local -a targets=("$HOME/.zshrc" "$HOME/.p10k.zsh" "$config_dir/conky/conky.conf"
        "$config_dir/conky/start-hud.sh" "$config_dir/autostart/$autostart")
    local i
    for i in "${!sources[@]}"; do
        file="${sources[i]}"
        [[ -f "$dotfiles_dir/$file" && ! -L "$dotfiles_dir/$file" ]] ||
            die "Expected a regular file at $dotfiles_dir/$file."
        # Compare parent directories so an existing destination symlink is safe to reuse.
        [[ "$(realpath -m -- "$(dirname -- "${targets[i]}")")" != \
            "$(realpath -- "$(dirname -- "$dotfiles_dir/$file")")" ]] ||
            die "The destination for $file would replace the dotfiles source."
    done
    [[ -x "$dotfiles_dir/.config/conky/start-hud.sh" ]] ||
        die "The Conky HUD launcher must be executable."
    mkdir -p -- "$config_dir/conky" "$config_dir/autostart"
    for i in "${!sources[@]}"; do
        link_config "$dotfiles_dir/${sources[i]}" "${targets[i]}"
    done
    link_config "$config_dir/conky/conky.conf" "$HOME/.conkyrc"
}

configure_user() {
    local omz_dir="$HOME/.oh-my-zsh" zsh_path login_shell
    if [[ ! -d "$dotfiles_dir" ]]; then
        info "Cloning private dotfiles using your existing GitHub SSH credentials."
        if ! GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no' \
            git clone "$dotfiles_repo" "$dotfiles_dir"; then
            die "Could not clone dotfiles. Set up GitHub SSH access and verify its host key, or use an existing checkout via DOTFILES_DIR."
        fi
    fi
    dotfiles_dir=$(realpath -- "$dotfiles_dir")
    install_checkout https://github.com/ohmyzsh/ohmyzsh.git "$omz_dir"
    install_checkout https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM:-$omz_dir/custom}/themes/powerlevel10k" --depth=1
    deploy_configs

    zsh_path=$(command -v zsh)
    login_shell=$(getent passwd "$(id -un)" | cut -d: -f7)
    if [[ "$login_shell" != "$zsh_path" ]] && ! chsh -s "$zsh_path"; then
        warn "Could not change the login shell. Run chsh -s $zsh_path to retry."
    fi
}

main() {
    local package arch login_lock apt_dirs sourcelist sourceparts archive_configured=0
    local keyring=/usr/share/keyrings/zengolfer-archive-keyring.gpg
    local -a missing=()
    detect_release /etc/os-release
    if [[ "${1:-}" == --check && $# == 1 ]]; then
        package=$(select_fetch)
        info "Fetch utility from current PATH and cached APT indexes: ${package:-none}"
        return
    fi
    (( $# == 0 )) || die "Usage: $0 [--check]"
    (( EUID != 0 )) || die "Run this as your normal login user. The bootstrap uses sudo for system changes."
    command -v sudo >/dev/null || die "Install sudo and give your user sudo access first."
    [[ "$dotfiles_dir" == /* ]] || die "DOTFILES_DIR must be an absolute path."
    [[ "${XDG_CONFIG_HOME:-$HOME/.config}" == /* ]] || die "XDG_CONFIG_HOME must be an absolute path."

    # Hold an advisory lock on the home directory without creating a lock file.
    exec {login_lock}<"$HOME"
    flock -n "$login_lock" || die "Another bootstrap is running for this home directory."
    scratch=$(mktemp -d)
    trap 'rm -rf -- "$scratch"' EXIT
    trap 'printf "Error: bootstrap failed (status %s) at line %s. See the preceding output.\n" "$?" "$LINENO" >&2' ERR

    arch=$(dpkg --print-architecture)
    if [[ "$arch" == amd64 ]]; then
        # APT prints shell-quoted paths, including any administrator overrides.
        apt_dirs=$(apt-config shell sourcelist Dir::Etc::sourcelist/f sourceparts Dir::Etc::sourceparts/d)
        eval "$apt_dirs"
        [[ -n "${sourcelist:-}" && -n "${sourceparts:-}" ]] ||
            die "Cannot determine the active APT source paths."
        sourceparts=$(realpath -m -- "$sourceparts")
        if command -v python3 >/dev/null && command -v gpg >/dev/null && command -v gpgv >/dev/null; then
            info "Checking the signed personal APT repository before refreshing indexes."
            install_personal_source "$sourcelist" "$sourceparts" "$keyring"
            archive_configured=1
        elif [[ -e "$sourceparts/zengolfer.list" || -L "$sourceparts/zengolfer.list" ||
                -e "$keyring" || -L "$keyring" ]]; then
            die "Python 3 and GnuPG are needed to inspect and recover the existing personal APT source before refreshing indexes."
        fi
    fi

    info "Refreshing APT package lists."
    sudo apt-get -o APT::Update::Error-Mode=any update
    for package in "${required_packages[@]}"; do
        has_candidate "$package" || missing+=("$package")
    done
    (( ${#missing[@]} == 0 )) ||
        die "Required packages have no APT candidate: ${missing[*]}. Check your enabled repositories (including Ubuntu Universe)."
    sudo apt-get --no-remove --no-upgrade install -y "${required_packages[@]}"

    if [[ -d /run/systemd/system ]] && ! sudo systemctl enable --now ssh.service; then
        warn "Could not enable and start ssh.service."
    fi
    for package in "${optional_packages[@]}"; do
        install_optional "$package" || true
    done
    install_fetch

    if [[ "$arch" != amd64 ]]; then
        warn "Skipping the amd64 personal APT repository, Chrome and Discord on $arch."
    elif (( ! archive_configured )); then
        info "Configuring the signed personal APT repository."
        install_personal_source "$sourcelist" "$sourceparts" "$keyring"
    fi

    info "Downloading APT Contents indexes for apt-file."
    sudo apt-get -o APT::Update::Error-Mode=any update
    if [[ "$arch" == amd64 ]]; then
        install_optional bitchx || true
        install_desktop_apps
    fi

    configure_user
    info "Bootstrap complete. Log out and back in to use the new login shell."
}

bootstrap_entry=$(realpath -e -- "${BASH_SOURCE[0]}")
bootstrap_dir=$(dirname -- "$bootstrap_entry")
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    checkout_dir=$bootstrap_dir
    if [[ -d "$checkout_dir/../dotfiles/.git" ]]; then
        dotfiles_dir="${DOTFILES_DIR:-$checkout_dir/../dotfiles}"
    else
        dotfiles_dir="${DOTFILES_DIR:-$HOME/dotfiles}"
    fi
    main "$@"
fi
