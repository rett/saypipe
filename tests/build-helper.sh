#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export HOME=$tmp/home
mkdir -p "$HOME"

# Sourcing must never enter main, install packages, or inspect the host.
sudo() { echo 'unexpected sudo' >&2; return 99; }
# sudo itself is also stubbed, so neither route can install packages.
# shellcheck disable=SC2032
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
git_dirty='' git_origin=$FFMPEG_REPO git_shallow=true git_fail=''
git() {
    printf '%s\n' "$*" >> "$git_log"
    case $* in
        *'remote get-url origin') printf '%s\n' "$git_origin" ;;
        *'status --porcelain --untracked-files=all --ignore-submodules=none')
            [[ $git_fail != status ]] || return 1
            printf '%s' "$git_dirty"
            ;;
        *'rev-parse --is-shallow-repository') printf '%s\n' "$git_shallow" ;;
        *'fetch --depth 1 origin '*) [[ $git_fail != fetch ]] ;;
        *'checkout --no-overwrite-ignore --detach -q FETCH_HEAD') return 0 ;;
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
git_dirty='' git_shallow=false
reject checkout_source "$tree" "$FFMPEG_REPO" release/8.1
test "$(cat "$tree/precious")" = keep
git_shallow=true
checkout_source "$tree" "$FFMPEG_REPO" release/8.1
grep -q 'fetch --depth 1 origin release/8.1' "$git_log"
grep -q 'checkout --no-overwrite-ignore --detach -q FETCH_HEAD' "$git_log"
test "$(cat "$tree/.git/saypipe-build-owned")" = "$FFMPEG_REPO"
git_dirty='?? work'
reject checkout_source "$tree" "$FFMPEG_REPO" release/9.0
git_dirty='' git_shallow=false
checkout_source "$tree" "$FFMPEG_REPO" release/9.0
grep -q 'fetch --depth 1 origin release/9.0' "$git_log"
for git_fail in status fetch; do
    reject checkout_source "$tree" "$FFMPEG_REPO" release/9.0
done
git_fail=''
mkdir -p "$tmp/waypipe/.git"
git_origin=$WAYPIPE_REPO git_shallow=true
checkout_source "$tmp/waypipe" "$WAYPIPE_REPO" v0.11.3
git_dirty='?? local-work'
reject checkout_source "$tmp/waypipe" "$WAYPIPE_REPO" v0.11.4
git_dirty=''
mkdir "$tmp/build"
touch "$tmp/build/precious"
reject prepare_build_dir "$tmp/build" "$WAYPIPE_REPO"
test -f "$tmp/build/precious"
prepare_build_dir "$tmp/owned-build" "$WAYPIPE_REPO"
touch "$tmp/owned-build/generated"
prepare_build_dir "$tmp/owned-build" "$WAYPIPE_REPO"
test ! -e "$tmp/owned-build/generated"
echo 'ok: build helper path, checkout, build ownership and source guard'

# Every privileged command below is emulated on fixtures within $tmp.
sudo_log=$tmp/sudo.log
pkg_log=$tmp/pkg.log
fail_at=
sudo() {
    printf '%s\n' "$*" >> "$sudo_log"
    case $1 in
        ldconfig) [[ $fail_at != ldconfig ]]; return ;;
        chown) return 0 ;;
        cp)
            printf 'copy-mode=%s\n' "$(stat -c %a "${@: -1}")" >> "$sudo_log"
            [[ $fail_at != copy ]] || return 1
            ;;
        mv)
            if [[ $fail_at == activate && $3 == *.new.* ]]; then return 1; fi
            ;;
        mkdir|mktemp|rmdir|rm|tee|chmod) ;;
        *) echo "unexpected privileged command: $*" >&2; return 99 ;;
    esac
    # Refuse any accidental privileged operation outside the test fixtures.
    local arg
    for arg in "$@"; do
        [[ $arg != /* || $arg == "$tmp" || $arg == "$tmp/"* ]] || return 99
    done
    command "$@"
}
pkg-config() {
    printf '%s|%s|%s\n' "${PKG_CONFIG_PATH:-}" "${PKG_CONFIG_LIBDIR:-}" "$*" >> "$pkg_log"
    [[ $fail_at != pkgconfig ]]
}
avutil_min=60 avcodec_min=62
stage=$tmp/staged
mkdir -p "$stage/lib/pkgconfig"
printf 'saypipe-build-ffmpeg-v1\n' > "$stage/.build-info"
printf 'new\n' > "$stage/version"
chmod 700 "$stage"
FFMPEG_PREFIX=$tmp/installed
mkdir "$FFMPEG_PREFIX"
printf 'saypipe-build-ffmpeg-v1\n' > "$FFMPEG_PREFIX/.build-info"
printf 'old\n' > "$FFMPEG_PREFIX/version"
linker_fixture=$tmp/linker.conf
printf 'previous\n\n' > "$linker_fixture"
cp "$linker_fixture" "$tmp/linker.expected"

transaction() (
    init_transaction
    linker_config=$linker_fixture
    trap 'finish_build "$?" || exit "$?"' EXIT
    install_staged_ffmpeg "$stage" || exit 42
    register_ffmpeg || exit 42
    # The previous prefix must survive until final waypipe verification.
    [[ -z $ffmpeg_backup ]] || test "$(cat "$ffmpeg_backup/version")" = old
    [[ $1 == success ]] || exit 42
)
for fail_at in pkgconfig copy activate ldconfig ''; do
    reject transaction failure
    test "$(cat "$FFMPEG_PREFIX/version")" = old
    cmp "$linker_fixture" "$tmp/linker.expected"
    test ! -e "$FFMPEG_PREFIX.saypipe-lock"
    [[ -z $(find "$tmp" -maxdepth 1 \( -name 'installed.new.*' -o -name 'installed.old.*' \) -print) ]]
done
grep -q -- "--define-variable=prefix=$stage" "$pkg_log"
grep -q "^|$stage/lib/pkgconfig|" "$pkg_log"
transaction success
test "$(cat "$FFMPEG_PREFIX/version")" = new
test "$(stat -c %a "$FFMPEG_PREFIX")" = 755
grep -q 'copy-mode=755' "$sudo_log"
if grep -q 'copy-mode=700' "$sudo_log"; then
    echo 'pending prefix inaccessible before copy' >&2
    exit 1
fi
test "$(cat "$linker_fixture")" = "$FFMPEG_PREFIX/lib"
[[ -z $(find "$tmp" -maxdepth 1 -name 'installed.old.*' -print) ]]

# A first install must disappear again when verification fails.
rm -rf "$FFMPEG_PREFIX"
rm "$linker_fixture"
reject transaction failure
test ! -e "$FFMPEG_PREFIX"
test ! -e "$linker_fixture"
mkdir "$FFMPEG_PREFIX.saypipe-lock"
reject transaction failure
test -d "$FFMPEG_PREFIX.saypipe-lock"
rmdir "$FFMPEG_PREFIX.saypipe-lock"
echo 'ok: staged pkg-config validation, replacement, rollback and commit'
