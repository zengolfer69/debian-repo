#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source-path=SCRIPTDIR source=../zengolfer-bootstrap.sh
source "$repo/zengolfer-bootstrap.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
scratch="$tmp/scratch"
parts="$tmp/sources.list.d"
main="$tmp/sources.list"
keyring="$tmp/keyring.gpg"
managed="$parts/zengolfer.list"
mkdir -m 0700 "$scratch"
mkdir "$parts" "$tmp/bin"
export PATH="$tmp/bin:$PATH"

# Exercise the production rename and cleanup in the fixture without privileges.
sudo() { "$@"; }
cat > "$tmp/bin/install" <<'MOCK'
#!/bin/bash
[[ "$1 $2 $3 $4" == '-o root -g root' ]] || exit 90
shift 4
exec /usr/bin/install "$@"
MOCK
cat > "$tmp/bin/mv" <<'MOCK'
#!/bin/bash
if [[ "${INTERRUPT_APT_RENAME:-}" == "${!#}" ]]; then
    kill -KILL "$PPID"
    exit 91
fi
exec /usr/bin/mv "$@"
MOCK
chmod +x "$tmp/bin/install" "$tmp/bin/mv"

deploy() { install_personal_source "$main" "$parts" "$keyring"; }
reject() {
    local expected="$1"
    if (deploy) >"$tmp/stdout" 2>"$tmp/stderr"; then
        printf 'Expected APT source rejection.\n' >&2
        return 1
    fi
    grep -Fq -- "$expected" "$tmp/stderr"
}

printf 'deb https://example.invalid/team stable main\n' > "$main"
cp "$main" "$tmp/main.before"
printf '# deb %s stable main\n' "$personal_repo" > "$parts/commented.list"
cat > "$parts/disabled.sources" <<SOURCES
Types: deb
URIs: $personal_repo/
Suites: stable
Components: main
Enabled: no
SOURCES
cp "$parts/disabled.sources" "$tmp/disabled.before"
printf 'deb [signed-by=%s] %s sta' "$keyring" "$personal_repo" > "$managed"
printf 'unreadable old keyring bytes' > "$keyring"
deploy
grep -Fxq "deb [arch=amd64 signed-by=$keyring] $personal_repo stable main" "$managed"
cmp "$repo/repo-key.gpg" "$keyring"
cmp "$tmp/main.before" "$main"
cmp "$tmp/disabled.before" "$parts/disabled.sources"
printf 'deb [arch=amd64 signed-by=%s] %s' "$keyring" "${personal_repo%repo}" > "$managed"
deploy
grep -Fxq "deb [arch=amd64 signed-by=$keyring] $personal_repo stable main" "$managed"

# A valid unrelated entry in the reserved file must survive intact.
cp "$managed" "$tmp/managed.before"
cat "$tmp/main.before" >> "$managed"
cp "$managed" "$tmp/mixed.before"
reject 'contains a custom source definition'
cmp "$tmp/mixed.before" "$managed"
cp "$tmp/managed.before" "$managed"

# Mixed-format duplicates with equivalent URL spelling are rejected verbatim.
printf 'deb [signed-by=%s] https://ZENGOLFER69.github.io:443/debian-%%72epo/ stable main\n' "$keyring" > "$parts/extra.list"
cp "$parts/extra.list" "$tmp/extra.before"
reject 'Duplicate or conflicting'
cmp "$tmp/extra.before" "$parts/extra.list"
cmp "$tmp/managed.before" "$managed"
rm "$parts/extra.list"
cat > "$parts/extra.sources" <<SOURCES
Types: deb
URIs: https://zengolfer69.github.io/debian-repo/
Suites: stable
Components: main
Signed-By: $keyring
SOURCES
cp "$parts/extra.sources" "$tmp/extra.before"
reject 'Duplicate or conflicting'
cmp "$tmp/extra.before" "$parts/extra.sources"
rm "$managed"
deploy
test ! -e "$managed"
cmp "$tmp/extra.before" "$parts/extra.sources"
sed -i '/Signed-By:/d' "$parts/extra.sources"
reject 'lacks scoped Signed-By'
rm "$parts/extra.sources"

# Inline deb822 key material has the same fingerprint requirement.
{
    printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By:\n' "$personal_repo"
    gpg --batch --enarmor < "$repo/repo-key.gpg" |
        sed -e 's/PGP ARMORED FILE/PGP PUBLIC KEY BLOCK/' -e '/^Comment:/d' -e 's/^$/./' -e 's/^/ /'
} > "$parts/inline.sources"
deploy
test ! -e "$managed"
rm "$parts/inline.sources"

# A pre-rename kill must leave the valid destination untouched.
deploy
printf 'replacement fixture\n' > "$tmp/replacement"
cp "$managed" "$tmp/managed.before"
if INTERRUPT_APT_RENAME="$managed" atomic_install_apt_file "$tmp/replacement" "$managed" 2>"$tmp/stderr"; then
    exit 1
fi
cmp "$tmp/managed.before" "$managed"
compgen -G "$parts/.zengolfer.list.tmp.*" >/dev/null
deploy
cmp "$tmp/managed.before" "$managed"

# Recovery also works when the key was published before the source rename.
printf 'deb [signed-by=%s] %s stable' "$keyring" "$personal_repo" > "$managed"
printf 'old key contents' > "$keyring"
cp "$managed" "$tmp/partial.before"
if INTERRUPT_APT_RENAME="$managed" deploy 2>"$tmp/stderr"; then
    exit 1
fi
cmp "$repo/repo-key.gpg" "$keyring"
cmp "$tmp/partial.before" "$managed"
deploy
cmp "$tmp/managed.before" "$managed"

# Invalid bundled replacement material cannot clobber a working archive.
mkdir -p "$tmp/bad/lib"
cp "$repo/lib/personal-apt-sources.py" "$tmp/bad/lib/"
printf 'invalid replacement key' > "$tmp/bad/repo-key.gpg"
(bootstrap_dir="$tmp/bad"; reject 'Cannot read the personal archive signing key')
cmp "$repo/repo-key.gpg" "$keyring"
cmp "$tmp/managed.before" "$managed"
# APT itself must accept the recovered files and ignore abandoned temp files.
apt-get -o "Dir::Etc::sourcelist=$main" -o "Dir::Etc::sourceparts=$parts" indextargets >/dev/null

# Stop at the first simulated APT refresh and check the recovery ordering.
(
    export HOME="$tmp/home"
    mkdir "$HOME"
    dotfiles_dir="$repo"
    dpkg() { printf 'amd64\n'; }
    apt-config() { printf 'sourcelist=%q\nsourceparts=%q\n' "$main" "$parts"; }
    install_personal_source() { printf 'repair\n' >> "$tmp/order"; }
    sudo() {
        [[ "$1" == apt-get && "$*" == *' update' ]] || exit 99
        printf 'refresh\n' >> "$tmp/order"
        exit 0
    }
    main
)
test "$(cat "$tmp/order")" = $'repair\nrefresh'
printf 'Personal APT source and recovery regression cases passed.\n'
