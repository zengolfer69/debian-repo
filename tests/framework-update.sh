#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source-path=SCRIPTDIR source=../zengolfer-bootstrap.sh
source "$repo/zengolfer-bootstrap.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
upstream="$tmp/upstream"
target="$tmp/installed"
export GIT_AUTHOR_NAME='Framework fixture' GIT_AUTHOR_EMAIL='fixture@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git init -q -b main "$upstream"
git -C "$upstream" commit --allow-empty -qm initial
baseline=$(git -C "$upstream" rev-parse HEAD)
git clone -q "$upstream" "$target"

printf 'local.conf\n' >> "$target/.git/info/exclude"
printf 'private local settings\n' > "$target/local.conf"
test -z "$(git -C "$target" status --porcelain)"
printf 'different upstream settings\n' > "$upstream/local.conf"
git -C "$upstream" add local.conf
git -C "$upstream" commit -qm 'track the formerly ignored path'
install_checkout "$upstream" "$target" 2>"$tmp/skip"
grep -Fq 'Skipping framework update' "$tmp/skip"
test "$(git -C "$target" rev-parse HEAD)" = "$baseline"
test "$(cat "$target/local.conf")" = 'private local settings'

mv "$target/local.conf" "$tmp/preserved"
printf 'keep this untracked file\n' > "$target/untracked"
install_checkout "$upstream" "$target" 2>"$tmp/skip"
grep -Fq 'checkout has local changes' "$tmp/skip"
test "$(git -C "$target" rev-parse HEAD)" = "$baseline"
test "$(cat "$target/untracked")" = 'keep this untracked file'

mv "$target/untracked" "$tmp/untracked"
install_checkout "$upstream" "$target"
test "$(git -C "$target" rev-parse HEAD)" = "$(git -C "$upstream" rev-parse HEAD)"
test "$(cat "$tmp/preserved")" = 'private local settings'
printf 'Framework update regression cases passed.\n'
