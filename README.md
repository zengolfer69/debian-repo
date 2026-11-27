# Personal Debian and Ubuntu bootstrap

This repository hosts the signed personal APT archive and the bootstrap for
Debian 12 Bookworm, Debian 13 Trixie, Debian Testing, Debian Unstable (Sid),
Ubuntu 24.04 LTS, and newer Ubuntu releases. Testing and Sid use the same package
selection as other Debian releases, including when `VERSION_ID` is absent.
Package availability depends on the enabled APT sources and architecture.

## Install

Install Git and make sure your login account has working sudo access. On Ubuntu,
enable Universe for the development and desktop packages. Set up GitHub SSH
access for the private dotfiles repository and verify GitHub's host key before
connecting. The bootstrap leaves your SSH keys, SSH configuration, and
`known_hosts` alone.

```bash
mkdir -p "$HOME/src"
git clone https://github.com/zengolfer69/debian-repo.git "$HOME/src/debian-repo"
cd "$HOME/src/debian-repo"
./zengolfer-bootstrap.sh --check
./zengolfer-bootstrap.sh
```

Run as your regular user. The script uses sudo for package and service changes.
It uses an existing sibling `dotfiles` checkout when available. Otherwise it
uses or clones `$HOME/dotfiles`. Set `DOTFILES_DIR` to an absolute path to choose
a checkout explicitly. Update an existing dotfiles checkout with Git when you
want to deploy a newer revision. The `--check` option reports the detected
release and fetch utility using the current PATH and cached APT metadata,
without changing the host.

## Packages and configuration

- APT installs the core development and Debian packaging toolchain, OpenSSH,
  Zsh, Conky, and apt-file. After apt-file is installed, a second index refresh
  downloads the configured Contents indexes. Missing required packages and
  failed index refreshes stop the run.
- Fastfetch is preferred when installed or installable. Neofetch is the fallback.
  Optional tools such as ddate, ltrace, checkinstall, and the Hack fonts report a
  skip when unavailable.
- On amd64, the bootstrap configures the signed personal archive in
  `/etc/apt/sources.list.d/zengolfer.list` and attempts to install BitchX. The
  published `bitchx_1.2.1-1_amd64.deb` requires glibc 2.38 or later and
  `libssl3t64`. Stock Bookworm cannot install it. A Bookworm-compatible package
  has to be built and published to the signed archive to provide BitchX there.
  Chrome and Discord are optional amd64 installs. Chrome uses an existing APT
  candidate or Google's vendor package, which manages its update source.
- The personal source check reads the configured APT source list and enabled
  `.list` and `.sources` entries. It reuses one compatible external definition
  with a readable keyring or inline key matching the pinned fingerprint. It
  reports conflicting definitions with their locations for manual resolution.
  The bootstrap reserves `zengolfer.list` for its own entry and repairs legacy
  partial writes before refreshing APT. Python 3, GnuPG, and gpgv must already
  be available when recovering an existing managed archive.
- The bootstrap enables the SSH service on systemd systems, installs or
  safely fast-forwards Oh My Zsh and Powerlevel10k checkouts, links user
  configuration, and requests a login-shell change if needed. It reports and
  skips updates when Git would overwrite local files or cannot fast-forward.
- Conky uses the dotfiles HUD through
  `${XDG_CONFIG_HOME:-$HOME/.config}/conky/conky.conf`. The legacy `~/.conkyrc`
  links to the same HUD. The bootstrap also links the launcher and its XDG
  autostart entry for the next graphical login. Existing configs and symlinks
  get unique `.pre-bootstrap` backups when replaced. Correct links are reused
  on reruns.

See the dotfiles README for Conky launch and backup details.

## Regression tests

From the directory containing both checkouts, run:

```bash
for test_script in debian-repo/tests/*.sh dotfiles/tests/*.sh; do
    bash "$test_script" || exit
done
```

The fixtures use temporary checkouts and simulated privileged operations.
They do not update the host APT sources, shell, or desktop configuration.
