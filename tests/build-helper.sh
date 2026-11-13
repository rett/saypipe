#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export HOME=$tmp/home
mkdir -p "$HOME"

# Sourcing must never enter main, install packages, or inspect the host.
sudo() { echo 'unexpected sudo' >&2; return 99; }
apt-get() { echo 'unexpected apt-get' >&2; return 99; }
nproc() { echo 'unexpected nproc' >&2; return 99; }
source "$root/scripts/build-waypipe.sh"
reject() { if ( "$@" ) >"$tmp/rejected" 2>&1; then echo "unexpected success: $*" >&2; exit 1; fi; }

for path in / /opt /opt/ /usr /usr/ /usr/local /usr/local/ relative /opt/../usr /opt/./ffmpeg //opt/ffmpeg; do
    reject validate_prefix "$path"
done
validate_prefix "$tmp/private-ffmpeg"
FFMPEG_PREFIX=$tmp/private-ffmpeg
mkdir "$FFMPEG_PREFIX"
reject check_prefix
printf 'branch=old\n' > "$FFMPEG_PREFIX/.build-info"
reject check_prefix
printf 'saypipe-build-ffmpeg-v1\n' > "$FFMPEG_PREFIX/.build-info"
check_prefix
ln -s "$FFMPEG_PREFIX" "$tmp/link"
reject validate_prefix "$tmp/link/child"

git_log=$tmp/git.log
git_dirty= git_origin=$FFMPEG_REPO git_shallow=true
git() {
    printf '%s\n' "$*" >> "$git_log"
    case $* in
        *'remote get-url origin') printf '%s\n' "$git_origin" ;;
        *'status --porcelain --untracked-files=all') printf '%s' "$git_dirty" ;;
        *'rev-parse --is-shallow-repository') printf '%s\n' "$git_shallow" ;;
        *'fetch --depth 1 origin '*|*'checkout --detach -q FETCH_HEAD') return 0 ;;
        *) echo "unexpected git: $*" >&2; return 98 ;;
    esac
}
tree=$tmp/source
mkdir "$tree"
printf 'keep\n' > "$tree/precious"
reject checkout_source "$tree" "$FFMPEG_REPO" release/8.1
mkdir "$tree/.git"
git_origin=unfamiliar
reject checkout_source "$tree" "$FFMPEG_REPO" release/8.1
git_origin=$FFMPEG_REPO git_dirty=' M file'
reject checkout_source "$tree" "$FFMPEG_REPO" release/8.1
git_dirty= git_shallow=false
reject checkout_source "$tree" "$FFMPEG_REPO" release/8.1
test "$(cat "$tree/precious")" = keep
git_shallow=true
checkout_source "$tree" "$FFMPEG_REPO" release/8.1
grep -q 'fetch --depth 1 origin release/8.1' "$git_log"
grep -q 'checkout --detach -q FETCH_HEAD' "$git_log"
test "$(cat "$tree/.git/saypipe-build-owned")" = "$FFMPEG_REPO"
git_dirty='?? work'
reject checkout_source "$tree" "$FFMPEG_REPO" release/9.0
git_dirty= git_shallow=false
checkout_source "$tree" "$FFMPEG_REPO" release/9.0
grep -q 'fetch --depth 1 origin release/9.0' "$git_log"
mkdir "$tmp/build"
touch "$tmp/build/precious"
reject prepare_build_dir "$tmp/build" "$WAYPIPE_REPO"
test -f "$tmp/build/precious"
prepare_build_dir "$tmp/owned-build" "$WAYPIPE_REPO"
touch "$tmp/owned-build/generated"
prepare_build_dir "$tmp/owned-build" "$WAYPIPE_REPO"
test ! -e "$tmp/owned-build/generated"
echo 'ok: build helper path, checkout, build ownership and source guard'
