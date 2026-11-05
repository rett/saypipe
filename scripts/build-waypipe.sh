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
# sonames, registered with ldconfig, so nothing else on the system changes) and
# reused on later runs for as long as it still meets the minimum.
#
# Run as your normal user (sudo is used where needed):
#   ./scripts/build-waypipe.sh
#
# Re-runnable: completed steps are skipped; rerun to update to a newer release.
#
# Environment overrides:
#   WAYPIPE_VER=v0.11.3          build this tag instead of the latest release
#   FFMPEG_BRANCH=release/8.1    branch for a private ffmpeg build
#                                (default: the newest release/* branch)
#   FFMPEG_REBUILD=1             rebuild the private ffmpeg even if it qualifies
#   FFMPEG_PREFIX=/opt/ffmpeg-waypipe   PREFIX=/usr/local   SRC=$HOME/src

set -euo pipefail

WAYPIPE_REPO=https://gitlab.freedesktop.org/mstoeckl/waypipe.git
FFMPEG_REPO=https://git.ffmpeg.org/ffmpeg.git
FFMPEG_PREFIX=${FFMPEG_PREFIX:-/opt/ffmpeg-waypipe}
PREFIX=${PREFIX:-/usr/local}
SRC=${SRC:-$HOME/src}
JOBS=$(nproc)

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

# own_tree <dir>: give a tree back to the current user (after sudo installs)
own_tree() { [[ -e $1 ]] && sudo chown -R "$(id -u):$(id -g)" "$1"; return 0; }

[[ $EUID -eq 0 ]] && die "run as your normal user, not root (sudo is used where needed)"
command -v apt-get >/dev/null 2>&1 ||
    die "only apt-based systems (Debian, Ubuntu and derivatives) are supported for now"
# shellcheck disable=SC1091
. /etc/os-release
log "Building waypipe on ${PRETTY_NAME:-unknown system}"
mkdir -p "$SRC"

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

if [[ ! -d $SRC/waypipe/.git ]]; then
    git clone --branch "$WAYPIPE_VER" --depth 1 "$WAYPIPE_REPO" "$SRC/waypipe"
fi
cd "$SRC/waypipe"
git fetch --depth 1 origin tag "$WAYPIPE_VER" >/dev/null 2>&1 || true
git -c advice.detachedHead=false checkout -q "$WAYPIPE_VER" ||
    die "cannot check out $WAYPIPE_VER in $SRC/waypipe"

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
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        fi
    fi
    rustup toolchain list | grep -q '^stable' || rustup toolchain install stable
    rustup default stable >/dev/null
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
# ffmpeg_ok [pkg-config dir]: libavutil/libavcodec there (or system) qualify
ffmpeg_ok() {
    [[ -n $avutil_min && -n $avcodec_min ]] || return 1
    if [[ -n ${1:-} ]]; then
        PKG_CONFIG_LIBDIR=$1 pkg-config --atleast-version "$avutil_min" libavutil &&
        PKG_CONFIG_LIBDIR=$1 pkg-config --atleast-version "$avcodec_min" libavcodec
    else
        pkg-config --atleast-version "$avutil_min" libavutil &&
        pkg-config --atleast-version "$avcodec_min" libavcodec
    fi
}

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

    # A checkout of another branch is ours to replace.
    if [[ -d $SRC/ffmpeg/.git ]] &&
       [[ $(git -C "$SRC/ffmpeg" rev-parse --abbrev-ref HEAD 2>/dev/null) != "$FFMPEG_BRANCH" ]]; then
        rm -rf "$SRC/ffmpeg" 2>/dev/null || sudo rm -rf "$SRC/ffmpeg"
    fi
    [[ -d $SRC/ffmpeg/.git ]] ||
        git clone --depth 1 --branch "$FFMPEG_BRANCH" "$FFMPEG_REPO" "$SRC/ffmpeg"

    codecs=()
    pkg-config --exists x264      && codecs+=(--enable-libx264)
    pkg-config --exists vpx       && codecs+=(--enable-libvpx)
    pkg-config --exists dav1d     && codecs+=(--enable-libdav1d)
    pkg-config --exists aom       && codecs+=(--enable-libaom)
    pkg-config --exists SvtAv1Enc && codecs+=(--enable-libsvtav1)

    cd "$SRC/ffmpeg"
    make distclean >/dev/null 2>&1 || true
    ./configure \
        --prefix="$FFMPEG_PREFIX" \
        --enable-shared --disable-static \
        --disable-programs --disable-doc \
        --disable-avdevice --disable-avformat --disable-avfilter \
        --disable-vulkan \
        --enable-gpl \
        "${codecs[@]}"
    make -j"$JOBS"
    # Replace, don't layer: a new major would otherwise leave stale sonames.
    [[ $FFMPEG_PREFIX == /opt/* && -d $FFMPEG_PREFIX ]] && sudo rm -rf "$FFMPEG_PREFIX"
    sudo make install
    own_tree "$SRC/ffmpeg"
    printf 'branch=%s\ncommit=%s\n' "$FFMPEG_BRANCH" "$(git rev-parse --short HEAD)" |
        sudo tee "$FFMPEG_PREFIX/.build-info" >/dev/null
    ffmpeg_ok "$FFMPEG_PREFIX/lib/pkgconfig" ||
        die "ffmpeg $FFMPEG_BRANCH does not meet libavutil >= $avutil_min / libavcodec >= $avcodec_min"
fi

if (( use_private )); then
    log "Registering $FFMPEG_PREFIX/lib with the dynamic linker"
    echo "$FFMPEG_PREFIX/lib" | sudo tee /etc/ld.so.conf.d/ffmpeg-waypipe.conf >/dev/null
    sudo ldconfig
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
if [[ -d build ]]; then rm -rf build 2>/dev/null || sudo rm -rf build; fi
meson setup build \
    --buildtype=release \
    -Dprefix="$PREFIX" \
    -Dbuild_rs=true -Dbuild_c=false -Dtests=false \
    -Dwith_dmabuf=enabled -Dwith_video=enabled \
    -Dwith_lz4=enabled -Dwith_zstd=enabled -Dwith_gbm=enabled \
    -Dman-pages=auto
ninja -C build
# --no-rebuild: root has no Rust toolchain, so installing must not run cargo.
sudo meson install -C build --no-rebuild
own_tree build
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
  sudo ninja -C $SRC/waypipe/build uninstall
EOF
if (( use_private )); then
    echo "  sudo rm -rf $FFMPEG_PREFIX /etc/ld.so.conf.d/ffmpeg-waypipe.conf && sudo ldconfig"
fi
