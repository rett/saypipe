#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Everett C. Haimes III
# build-waypipe.sh
#
# Builds the latest waypipe release with all features (dmabuf/Vulkan, lz4,
# zstd, gbm fallback, video) on apt-based systems (Debian, Ubuntu and their
# derivatives) and installs it to /usr/local.
#
# Optional for saypipe: saypipe works with your distribution's waypipe. Use
# this when that waypipe is too old for you (e.g. on LTS releases), or when
# you want waypipe's --video support, which needs a recent ffmpeg.
#
# Video needs a recent ffmpeg; the minimum libavutil/libavcodec versions are
# read from waypipe's own meson.build. If the system ffmpeg is new enough it is
# used. Otherwise a private ffmpeg is built into /opt/ffmpeg-waypipe (its own
# sonames, registered with ldconfig) and
# reused on later runs for as long as it still meets the minimum.
#
# Run as your normal user (sudo is used where needed):
#   ./scripts/build-waypipe.sh
#
# Re-runnable: completed steps are skipped; rerun to update to a newer release.
# Existing private prefixes need this helper's ownership metadata. Unfamiliar
# or dirty sources and unowned build directories require manual attention.
# A replacement FFmpeg is staged without sudo, with the old prefix retained
# until final waypipe verification. Linker registration is system-wide.
#
# Environment overrides:
#   WAYPIPE_VER=v0.11.3          build this tag instead of the latest release
#   FFMPEG_BRANCH=release/8.1    branch for a private ffmpeg build
#                                (default: the newest release/* branch)
#   FFMPEG_REBUILD=1             rebuild the private ffmpeg even if it qualifies
#   FFMPEG_PREFIX=/opt/ffmpeg-waypipe   PREFIX=/usr/local   SRC=$HOME/src

WAYPIPE_REPO=https://gitlab.freedesktop.org/mstoeckl/waypipe.git
FFMPEG_REPO=https://git.ffmpeg.org/ffmpeg.git
FFMPEG_PREFIX=${FFMPEG_PREFIX:-/opt/ffmpeg-waypipe}
PREFIX=${PREFIX:-/usr/local}
SRC=${SRC:-$HOME/src}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# version_ge <a> <b>: a >= b (Debian version ordering)
version_ge() { dpkg --compare-versions "$1" ge "$2"; }

# apt_has <pkg>: package has an installation candidate
apt_has() {
    local c
    c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')
    [[ -n $c && $c != "(none)" ]]
}

# Reject ambiguous paths and symlinked ancestors before any privileged operation.
validate_prefix() {
    local path=${1%/}
    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* ]] || return 1
    case /${path#/}/ in */../*|*/./*|*//*) return 1 ;; esac
    case $path in ''|/|/opt|/usr|/usr/local|/bin|/sbin|/lib|/lib64|/etc|/home|/var|/tmp) return 1 ;; esac
    [[ $(realpath -m -- "$path") == "$path" ]] || return 1
}

prefix_owned() {
    [[ -d $1 && ! -L $1 && -f $1/.build-info && ! -L $1/.build-info ]] &&
        [[ $(head -n 1 "$1/.build-info") == 'saypipe-build-ffmpeg-v1' ]]
}

check_prefix() {
    validate_prefix "$FFMPEG_PREFIX" || die "unsafe FFMPEG_PREFIX: $FFMPEG_PREFIX"
    FFMPEG_PREFIX=${FFMPEG_PREFIX%/}
    if [[ -e $FFMPEG_PREFIX || -L $FFMPEG_PREFIX ]]; then
        prefix_owned "$FFMPEG_PREFIX" || die "unowned FFmpeg prefix: $FFMPEG_PREFIX"
    fi
}

# Recognize clean shallow upstream clones too, but never claim arbitrary trees.
checkout_source() {
    local dir=$1 repo=$2 ref=$3 origin status shallow
    if [[ -e $dir || -L $dir ]]; then
        [[ -d $dir/.git && ! -L $dir && ! -L $dir/.git ]] || die "unfamiliar source tree: $dir"
        origin=$(git -C "$dir" remote get-url origin) || die "cannot read origin: $dir"
        [[ $origin == "$repo" ]] || die "unexpected origin: $dir"
        status=$(git -C "$dir" status --porcelain --untracked-files=all --ignore-submodules=none) || die "cannot inspect source tree: $dir"
        [[ -z $status ]] || die "dirty source tree: $dir"
        [[ ! -L $dir/.git/saypipe-build-owned ]] || die "symlinked source marker: $dir"
        if [[ ! -f $dir/.git/saypipe-build-owned ]]; then
            shallow=$(git -C "$dir" rev-parse --is-shallow-repository) || die "cannot inspect source history: $dir"
            [[ $shallow == true ]] || die "unowned source tree: $dir"
        else
            [[ $(cat "$dir/.git/saypipe-build-owned") == "$repo" ]] || die "invalid source marker: $dir"
        fi
        git -C "$dir" fetch --depth 1 origin "$ref" || die "cannot fetch source: $dir"
        git -C "$dir" -c advice.detachedHead=false checkout --no-overwrite-ignore --detach -q FETCH_HEAD || die "cannot update source: $dir"
    else
        git clone --depth 1 --branch "$ref" "$repo" "$dir" || die "cannot clone source: $dir"
        git -C "$dir" -c advice.detachedHead=false checkout --detach -q HEAD || die "cannot detach source: $dir"
    fi
    printf '%s\n' "$repo" > "$dir/.git/saypipe-build-owned"
}

prepare_build_dir() {
    local dir=$1 source=$2
    [[ ! -L $dir ]] || die "symlinked build directory: $dir"
    if [[ -e $dir ]]; then
        [[ -d $dir && -f $dir/.saypipe-build-owned && ! -L $dir/.saypipe-build-owned ]] &&
            [[ $(cat "$dir/.saypipe-build-owned") == "$source" ]] || die "unowned build directory: $dir"
        rm -rf -- "$dir"
    fi
    mkdir -- "$dir"
    printf '%s\n' "$source" > "$dir/.saypipe-build-owned"
}

# An explicit prefix override makes staged .pc files describe the staged tree.
ffmpeg_ok() {
    [[ -n $avutil_min && -n $avcodec_min ]] || return 1
    local libdir=${1:-} prefix=${2:-}
    local args=()
    [[ -z $prefix ]] || args+=("--define-variable=prefix=$prefix")
    if [[ -n $libdir ]]; then
        PKG_CONFIG_PATH='' PKG_CONFIG_LIBDIR=$libdir pkg-config "${args[@]}" --atleast-version "$avutil_min" libavutil &&
        PKG_CONFIG_PATH='' PKG_CONFIG_LIBDIR=$libdir pkg-config "${args[@]}" --atleast-version "$avcodec_min" libavcodec
    else
        pkg-config --atleast-version "$avutil_min" libavutil &&
        pkg-config --atleast-version "$avcodec_min" libavcodec
    fi
}

init_transaction() {
    ffmpeg_stage='' ffmpeg_pending='' ffmpeg_backup='' ffmpeg_swapped=0
    ffmpeg_lock=
    linker_changed=0 linker_existed=0 linker_previous=
    linker_config=/etc/ld.so.conf.d/ffmpeg-waypipe.conf
}

lock_ffmpeg() {
    [[ -z $ffmpeg_lock ]] || return 0
    sudo mkdir -p -- "$(dirname "$FFMPEG_PREFIX")" || return 1
    sudo mkdir -- "$FFMPEG_PREFIX.saypipe-lock" || {
        warn "cannot acquire build lock: $FFMPEG_PREFIX.saypipe-lock"
        return 1
    }
    ffmpeg_lock=$FFMPEG_PREFIX.saypipe-lock
}

# Only directories created by this transaction may be removed on failure.
remove_owned_prefix() {
    prefix_owned "$1" || { warn "refusing to remove unowned prefix: $1"; return 1; }
    sudo rm -rf -- "$1"
}

install_staged_ffmpeg() {
    local staged=$1
    check_prefix
    lock_ffmpeg || return 1
    check_prefix
    prefix_owned "$staged" || { warn "unowned staged FFmpeg: $staged"; return 1; }
    ffmpeg_ok "$staged/lib/pkgconfig" "$staged" || return 1
    ffmpeg_pending=$(sudo mktemp -d "$FFMPEG_PREFIX.new.XXXXXX") || return 1
    # Record ownership before copying, so a partial copy can be cleaned up.
    printf 'saypipe-build-ffmpeg-v1\n' | sudo tee "$ffmpeg_pending/.build-info" >/dev/null || return 1
    sudo cp -a -- "$staged/." "$ffmpeg_pending/" || return 1
    sudo chown -R root:root -- "$ffmpeg_pending" || return 1
    if [[ -e $FFMPEG_PREFIX ]]; then
        ffmpeg_backup=$(sudo mktemp -d "$FFMPEG_PREFIX.old.XXXXXX") || return 1
        sudo rmdir -- "$ffmpeg_backup" || return 1
        # Recheck immediately before moving the old prefix.
        prefix_owned "$FFMPEG_PREFIX" || return 1
        sudo mv -- "$FFMPEG_PREFIX" "$ffmpeg_backup" || return 1
    fi
    sudo mv -- "$ffmpeg_pending" "$FFMPEG_PREFIX" || return 1
    ffmpeg_pending='' ffmpeg_swapped=1
    ffmpeg_ok "$FFMPEG_PREFIX/lib/pkgconfig" || return 1
}

register_ffmpeg() {
    [[ ! -L $linker_config ]] || { warn "symlinked linker configuration: $linker_config"; return 1; }
    if [[ -e $linker_config ]]; then
        [[ -f $linker_config ]] || return 1
        linker_previous=$(cat "$linker_config" && printf '.') || return 1
        linker_previous=${linker_previous%.}
        linker_existed=1
    fi
    linker_changed=1
    printf '%s\n' "$FFMPEG_PREFIX/lib" | sudo tee "$linker_config" >/dev/null || return 1
    sudo ldconfig
}

finish_build() {
    local status=$1 failed=0
    if (( status != 0 )); then
        if (( ffmpeg_swapped )) ||
           [[ -n $ffmpeg_pending && ! -e $ffmpeg_pending && -e $FFMPEG_PREFIX ]]; then
            remove_owned_prefix "$FFMPEG_PREFIX" || failed=1
        fi
        if [[ -n $ffmpeg_backup && -d $ffmpeg_backup ]]; then
            if [[ ! -e $FFMPEG_PREFIX && ! -L $FFMPEG_PREFIX ]]; then
                sudo mv -- "$ffmpeg_backup" "$FFMPEG_PREFIX" || failed=1
            else
                warn "previous FFmpeg remains at $ffmpeg_backup"
                failed=1
            fi
        fi
        if (( linker_changed )); then
            if (( linker_existed )); then
                printf '%s' "$linker_previous" | sudo tee "$linker_config" >/dev/null || failed=1
            else
                sudo rm -f -- "$linker_config" || failed=1
            fi
            sudo ldconfig || failed=1
        fi
    elif [[ -n $ffmpeg_backup && -d $ffmpeg_backup ]]; then
        remove_owned_prefix "$ffmpeg_backup" || failed=1
    fi
    if [[ -n $ffmpeg_pending && -d $ffmpeg_pending ]]; then
        remove_owned_prefix "$ffmpeg_pending" || failed=1
    fi
    [[ -z $ffmpeg_stage ]] || rm -rf -- "$ffmpeg_stage" || failed=1
    [[ -z $ffmpeg_lock ]] || sudo rmdir -- "$ffmpeg_lock" || failed=1
    (( failed == 0 )) || { warn 'FFmpeg transaction cleanup needs manual attention'; return 1; }
    return "$status"
}

main() {
set -euo pipefail
JOBS=$(nproc)
check_prefix
SRC=$(realpath -m -- "$SRC")
init_transaction
trap 'finish_build "$?" || exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ $EUID -eq 0 ]] && die "run as your normal user, not root (sudo is used where needed)"
command -v apt-get >/dev/null 2>&1 ||
    die "only apt-based systems (Debian, Ubuntu and derivatives) are supported for now"
# shellcheck disable=SC1091
. /etc/os-release
log "Building waypipe on ${PRETTY_NAME:-unknown system}"
mkdir -p "$SRC"
lock_ffmpeg || die "another build may be using $FFMPEG_PREFIX"

# ----------------------------------------------------- 1. build dependencies --
log "Installing build dependencies"
sudo apt-get update
required=(build-essential git pkg-config meson ninja-build clang libclang-dev
          glslc liblz4-dev libzstd-dev libgbm-dev libvulkan-dev libdrm-dev
          curl ca-certificates)
optional=(scdoc)            # man pages
missing=()
for p in "${required[@]}"; do apt_has "$p" || missing+=("$p"); done
((${#missing[@]} == 0)) || die "packages not available on this system: ${missing[*]}"
install=("${required[@]}")
for p in "${optional[@]}"; do apt_has "$p" && install+=("$p"); done
sudo apt-get install -y --no-install-recommends "${install[@]}"

# ---------------------------------------------------------- 2. waypipe source --
if [[ -n ${WAYPIPE_VER:-} ]]; then
    log "Using requested waypipe $WAYPIPE_VER"
else
    log "Looking up the latest waypipe release"
    WAYPIPE_VER=$(git ls-remote --tags --refs "$WAYPIPE_REPO" |
        grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's|refs/tags/||' |
        sort -V | tail -n 1)
    [[ -n $WAYPIPE_VER ]] || die "could not determine the latest waypipe release"
    echo "Latest release: $WAYPIPE_VER"
fi

checkout_source "$SRC/waypipe" "$WAYPIPE_REPO" "$WAYPIPE_VER"
cd "$SRC/waypipe"

# meson_min <name>: minimum version waypipe's meson.build asks for <name>
meson_min() {
    awk -v name="'$1'" 'index($0, name) {f = 1}
        f && /version/ {match($0, /[0-9]+(\.[0-9]+)*/); print substr($0, RSTART, RLENGTH); exit}' \
        meson.build
}
cargo_rust_min=$(sed -nE 's/^rust-version *= *"([0-9.]+)".*/\1/p' Cargo.toml | head -n 1)
bindgen_min=$(meson_min bindgen)
avutil_min=$(meson_min libavutil)
avcodec_min=$(meson_min libavcodec)
echo "Requirements: rust >= ${cargo_rust_min:-?}, bindgen >= ${bindgen_min:-?}," \
     "libavutil >= ${avutil_min:-?}, libavcodec >= ${avcodec_min:-?}"

# ----------------------------------------------------------------- 3. rust ----
log "Setting up Rust >= ${cargo_rust_min:-stable}"
export PATH="$HOME/.cargo/bin:$PATH"
rust_ok() {
    command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 || return 1
    [[ -z $cargo_rust_min ]] || version_ge "$(rustc --version | awk '{print $2}')" "$cargo_rust_min"
}
if ! rust_ok; then
    if ! command -v rustup >/dev/null 2>&1; then
        if apt_has rustup; then
            sudo apt-get install -y rustup
        else
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none
        fi
    fi
    rustup toolchain list | grep -q '^stable' || rustup toolchain install stable
    export RUSTUP_TOOLCHAIN=stable
    hash -r
    rust_ok || die "Rust is still older than $cargo_rust_min"
fi
rustc --version
cargo --version

bindgen_ok() {
    command -v bindgen >/dev/null 2>&1 || return 1
    version_ge "$(bindgen --version | awk '{print $2}')" "${bindgen_min:-0.70.0}"
}
if ! bindgen_ok && apt_has bindgen; then
    sudo apt-get install -y --no-install-recommends bindgen
    hash -r
fi
if ! bindgen_ok; then
    log "Installing bindgen-cli >= ${bindgen_min:-0.70.0} with cargo (the packaged one is too old)"
    cargo install bindgen-cli --locked
    hash -r
fi
bindgen --version

# ---------------------------------------------------------------- 4. ffmpeg ----
# Does the distro ship a new enough ffmpeg? libavutil-dev depends on libavutilNN,
# so compare that soname major before installing anything.
use_private=1
if apt_has libavutil-dev && apt_has libavcodec-dev && [[ -n $avutil_min ]]; then
    distro_major=$(apt-cache depends libavutil-dev 2>/dev/null |
        grep -oE 'libavutil[0-9]+' | head -n 1 | grep -oE '[0-9]+' || true)
    if [[ -n $distro_major ]] && (( distro_major >= ${avutil_min%%.*} )); then
        sudo apt-get install -y --no-install-recommends libavutil-dev libavcodec-dev
        ffmpeg_ok && use_private=0
    fi
fi

if (( use_private == 0 )); then
    log "Using the system ffmpeg (libavutil $(pkg-config --modversion libavutil))"
elif [[ -z ${FFMPEG_REBUILD:-} ]] && ffmpeg_ok "$FFMPEG_PREFIX/lib/pkgconfig"; then
    log "Reusing private ffmpeg in $FFMPEG_PREFIX" \
        "(libavutil $(PKG_CONFIG_LIBDIR=$FFMPEG_PREFIX/lib/pkgconfig pkg-config --modversion libavutil))"
else
    [[ -n $avutil_min ]] || warn "could not read waypipe's ffmpeg minimum; building a private ffmpeg"
    if [[ -z ${FFMPEG_BRANCH:-} ]]; then
        FFMPEG_BRANCH=$(git ls-remote --heads "$FFMPEG_REPO" 'release/*' |
            grep -oE 'release/[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
        [[ -n $FFMPEG_BRANCH ]] || die "could not determine the newest ffmpeg release branch"
    fi
    log "Building ffmpeg ($FFMPEG_BRANCH) into $FFMPEG_PREFIX"

    ff_deps=(nasm)
    for p in libx264-dev libvpx-dev libdav1d-dev libaom-dev libsvtav1enc-dev; do
        apt_has "$p" && ff_deps+=("$p")
    done
    sudo apt-get install -y --no-install-recommends "${ff_deps[@]}"

    checkout_source "$SRC/ffmpeg" "$FFMPEG_REPO" "$FFMPEG_BRANCH"

    codecs=()
    pkg-config --exists x264      && codecs+=(--enable-libx264)
    pkg-config --exists vpx       && codecs+=(--enable-libvpx)
    pkg-config --exists dav1d     && codecs+=(--enable-libdav1d)
    pkg-config --exists aom       && codecs+=(--enable-libaom)
    pkg-config --exists SvtAv1Enc && codecs+=(--enable-libsvtav1)

    prepare_build_dir "$SRC/ffmpeg-build" "$FFMPEG_REPO"
    cd "$SRC/ffmpeg-build"
    "$SRC/ffmpeg/configure" \
        --prefix="$FFMPEG_PREFIX" \
        --enable-shared --disable-static \
        --disable-programs --disable-doc \
        --disable-avdevice --disable-avformat --disable-avfilter \
        --disable-vulkan \
        --enable-gpl \
        "${codecs[@]}"
    make -j"$JOBS"
    ffmpeg_stage=$(mktemp -d)
    make DESTDIR="$ffmpeg_stage" install
    printf 'saypipe-build-ffmpeg-v1\nbranch=%s\ncommit=%s\n' \
        "$FFMPEG_BRANCH" "$(git -C "$SRC/ffmpeg" rev-parse --short HEAD)" > \
        "$ffmpeg_stage$FFMPEG_PREFIX/.build-info"
    install_staged_ffmpeg "$ffmpeg_stage$FFMPEG_PREFIX" ||
        die "could not install verified staged FFmpeg"
    ffmpeg_ok "$FFMPEG_PREFIX/lib/pkgconfig" ||
        die "ffmpeg $FFMPEG_BRANCH does not meet libavutil >= $avutil_min / libavcodec >= $avcodec_min"
fi

if (( use_private )); then
    log "Registering $FFMPEG_PREFIX/lib with the dynamic linker"
    register_ffmpeg
    export PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
avcodec_major=$(pkg-config --modversion libavcodec | cut -d. -f1)
# (no `ldconfig -p | grep -q`: an early grep exit + pipefail is a false failure)
[[ $(ldconfig -p) == *"libavcodec.so.$avcodec_major "* ]] ||
    die "libavcodec.so.$avcodec_major is not visible to the dynamic linker"

# --------------------------------------------------------------- 5. waypipe ---
log "Building waypipe $WAYPIPE_VER"
cd "$SRC/waypipe"
cargo fetch --locked
prepare_build_dir "$SRC/waypipe-build" "$WAYPIPE_REPO"
meson setup "$SRC/waypipe-build" \
    --buildtype=release \
    -Dprefix="$PREFIX" \
    -Dbuild_rs=true -Dbuild_c=false -Dtests=false \
    -Dwith_dmabuf=enabled -Dwith_video=enabled \
    -Dwith_lz4=enabled -Dwith_zstd=enabled -Dwith_gbm=enabled \
    -Dman-pages=auto
ninja -C "$SRC/waypipe-build"
# --no-rebuild: root has no Rust toolchain, so installing must not run cargo.
sudo meson install -C "$SRC/waypipe-build" --no-rebuild
hash -r

# ---------------------------------------------------------------- 6. verify ---
log "Verifying"
installed=$PREFIX/bin/waypipe
[[ -x $installed ]] || die "$installed was not installed"
version_out=$("$installed" --version)
printf '%s\n' "$version_out"
for f in video dmabuf lz4 zstd; do
    [[ $version_out == *"$f: true"* ]] || die "$f feature missing"
done
found=$(command -v waypipe || true)
[[ $found == "$installed" ]] ||
    warn "'waypipe' on PATH is ${found:-missing}, not $installed; check PATH order or remove the other copy"
if dpkg -s waypipe >/dev/null 2>&1; then
    warn "the distro waypipe package is also installed; $installed takes precedence only if $PREFIX/bin comes first in PATH"
fi

if (( use_private )); then ffmpeg_where="$FFMPEG_PREFIX (private, /etc/ld.so.conf.d/ffmpeg-waypipe.conf)"
else ffmpeg_where="system packages"; fi

cat <<EOF

Done.
  waypipe:  $installed  (${version_out%%$'\n'*})
  ffmpeg:   libavcodec.so.$avcodec_major from $ffmpeg_where
  sources:  $SRC/waypipe$( (( use_private )) && echo ", $SRC/ffmpeg")

Try it:
  waypipe --compress zstd ssh <host> <command>

To uninstall:
  sudo ninja -C $SRC/waypipe-build uninstall
EOF
if (( use_private )); then
    echo "  sudo rm -rf $FFMPEG_PREFIX /etc/ld.so.conf.d/ffmpeg-waypipe.conf && sudo ldconfig"
fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
