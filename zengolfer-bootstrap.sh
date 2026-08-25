#!/usr/bin/env bash

set -euo pipefail

echo "==> Updating package lists..."
sudo apt update

echo "==> Installing bootstrap prerequisites and base packages..."
sudo apt install -y \
    openssh-client \
    openssh-server \
    screen \
    zsh \
    ddate \
    git \
    curl \
    wget \
    rsync \
    ca-certificates \
    gnupg \
    conky-all

echo "==> Enabling SSH service..."
sudo systemctl enable --now ssh


echo "==> Configuring zengolfer APT repository..."

sudo install -d -m 0755 /usr/share/keyrings

curl -fsSL \
    https://zengolfer69.github.io/debian-repo/repo-key.gpg \
    -o /tmp/zengolfer-archive-keyring.gpg

sudo install -m 0644 \
    /tmp/zengolfer-archive-keyring.gpg \
    /usr/share/keyrings/zengolfer-archive-keyring.gpg

rm -f /tmp/zengolfer-archive-keyring.gpg

echo \
"deb [signed-by=/usr/share/keyrings/zengolfer-archive-keyring.gpg] https://zengolfer69.github.io/debian-repo stable main" \
    | sudo tee /etc/apt/sources.list.d/zengolfer.list >/dev/null


echo "==> Configuring Google Chrome Stable repository..."

curl -fsSL \
    https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor \
    > /tmp/google-chrome.gpg

sudo install -m 0644 \
    /tmp/google-chrome.gpg \
    /usr/share/keyrings/google-chrome.gpg

rm -f /tmp/google-chrome.gpg

echo \
"deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null


echo "==> Updating package lists with added repositories..."
sudo apt update

echo "==> Installing BitchX and Google Chrome Stable..."
sudo apt install -y \
    bitchx \
    google-chrome-stable


echo "==> Installing Discord..."

tmp_discord="$(mktemp --suffix=.deb)"
trap 'rm -f "$tmp_discord"' EXIT

curl -fL \
    "https://discord.com/api/download?platform=linux&format=deb" \
    -o "$tmp_discord"

sudo apt install -y "$tmp_discord"

rm -f "$tmp_discord"
trap - EXIT


echo "==> Installing/updating Oh My Zsh..."

OMZ_DIR="$HOME/.oh-my-zsh"

if [[ ! -d "$OMZ_DIR/.git" ]]; then
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_DIR"
else
    git -C "$OMZ_DIR" pull --ff-only
fi


echo "==> Installing/updating Powerlevel10k..."

P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"

if [[ ! -d "$P10K_DIR/.git" ]]; then
    git clone --depth=1 \
        https://github.com/romkatv/powerlevel10k.git \
        "$P10K_DIR"
else
    git -C "$P10K_DIR" pull --ff-only
fi


echo "==> Configuring personal dotfiles..."

DOTFILES_DIR="$HOME/dotfiles"
DOTFILES_REPO="https://github.com/zengolfer69/dotfiles.git"

if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
else
    git -C "$DOTFILES_DIR" pull --ff-only
fi


backup_and_link() {
    local source="$1"
    local target="$2"

    if [[ -e "$target" && ! -L "$target" ]]; then
        echo "Backing up existing $target to ${target}.pre-bootstrap"
        mv "$target" "${target}.pre-bootstrap"
    fi

    ln -sfn "$source" "$target"
}

backup_and_link "$DOTFILES_DIR/.zshrc" "$HOME/.zshrc"
backup_and_link "$DOTFILES_DIR/.p10k.zsh" "$HOME/.p10k.zsh"


echo "==> Setting zsh as the login shell..."

ZSH_PATH="$(command -v zsh)"

if [[ "$SHELL" != "$ZSH_PATH" ]]; then
    chsh -s "$ZSH_PATH"
else
    echo "zsh is already the login shell."
fi


echo
echo "==> Bootstrap complete."
echo "Log out and back in for the shell change to take effect."
