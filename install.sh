#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Everett C. Haimes III
# install.sh: install or uninstall saypipe.
#
#   ./install.sh                   install what saypipe needs (bash, an
#                                  OpenSSH client, waypipe), then copy
#                                  saypipe to $PREFIX/bin (default /usr/local/bin)
#                                  and its bash/zsh/fish completions to
#                                  $PREFIX/share
#   ./install.sh --user            same, but link saypipe into ~/.local/bin
#                                  (or $SAYPIPE_BIN_DIR) and the completions
#                                  into your own completion directories,
#                                  pointing at this checkout, so updating it
#                                  updates saypipe
#   ./install.sh [--user] --uninstall [--purge]
#                                  remove saypipe, its completions and your
#                                  host links to it;
#                                  --purge also closes saypipe's shared ssh
#                                  connections and deletes your saypipe config
#                                  and state. Packages are kept.
#
# POSIX sh, so it runs before bash is installed. Package managers: apt, dnf,
# yum, zypper, pacman, apk, xbps, emerge and FreeBSD pkg. Anything already on
# PATH is left alone. Run as your normal user; sudo or doas is used for
# packages and system-wide installs. Remote hosts need waypipe too (and, for
# audio, a PulseAudio-compatible client stack such as PipeWire's
# pipewire-pulse).

set -eu

SRC_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SRC=$SRC_DIR/saypipe

if [ -t 2 ]; then B='\033[1;34m' Y='\033[1;33m' R='\033[1;31m' N='\033[0m'
else B='' Y='' R='' N=''; fi
log()  { printf "${B}==>${N} %s\n" "$*"; }
warn() { printf "${Y}WARNING:${N} %s\n" "$*" >&2; }
die()  { printf "${R}ERROR:${N} %s\n" "$*" >&2; exit 1; }

usage() { sed -n "/^# install.sh:/,/^$/s/^# \{0,1\}//p" "$0"; }

have() { command -v "$1" >/dev/null 2>&1; }

check_bash() {
    have bash || die "bash 4.4 or newer is required but still not installed"
    bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' ||
        die "bash on PATH must be version 4.4 or newer"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif have sudo; then sudo "$@"
    elif have doas; then doas "$@"
    else die "need root for: $* (run as root, or install sudo or doas)"
    fi
}

# Stage copies in an exclusively created directory. Moving the completed file
# replaces an owned symlink without writing through it into another checkout.
copy_tmp=''
cleanup_copy() {
    [ -z "$copy_tmp" ] || as_root rm -rf -- "$copy_tmp"
    copy_tmp=''
}
install_copy() {
    _copy_dir=$2.new.$$
    as_root mkdir -m 0700 -- "$_copy_dir" || die "cannot stage $2"
    copy_tmp=$_copy_dir
    trap cleanup_copy 0
    trap 'exit 1' HUP INT TERM
    if as_root cp "$1" "$copy_tmp/file" &&
       as_root chmod "$3" "$copy_tmp/file" &&
       as_root mv -f "$copy_tmp/file" "$2"; then
        cleanup_copy
    else
        cleanup_copy
        die "failed to install $2"
    fi
}

# resolve <path>: absolute path with symlinks resolved, without relying on
# GNU readlink -f. (POSIX sh has no local variables, hence the _r prefix.)
resolve() {
    _rp=$1 _rn=0
    if readlink -f -- / >/dev/null 2>&1; then readlink -f -- "$_rp"; return; fi
    if have realpath; then realpath -- "$_rp" 2>/dev/null && return; fi
    while [ -L "$_rp" ] && [ $_rn -lt 40 ]; do
        _rl=$(readlink -- "$_rp") || break
        case $_rl in /*) _rp=$_rl ;; *) _rp=${_rp%/*}/$_rl ;; esac
        _rn=$((_rn + 1))
    done
    _rd=$(cd -P -- "$(dirname -- "$_rp")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$_rd" "${_rp##*/}"
}

# is_saypipe <file>: a saypipe script (so we never overwrite or delete others)
is_saypipe() { [ -f "$1" ] && grep -q '^# saypipe: run' "$1"; }

# The user whose links and config we manage: the invoking user, even under
# sudo/doas.
user_home() {
    _uh=$HOME
    _uu=${SUDO_USER:-${DOAS_USER:-}}
    if [ "$(id -u)" -eq 0 ] && [ -n "$_uu" ]; then
        _h=$(getent passwd "$_uu" 2>/dev/null | cut -d: -f6 || true)
        case $_uu in *[!A-Za-z0-9._-]*) ;; *) [ -n "$_h" ] || _h=$(eval "echo ~$_uu") ;; esac
        [ -n "$_h" ] && _uh=$_h
    fi
    printf '%s\n' "$_uh"
}

detect_pm() {
    if [ "$(uname -s)" = FreeBSD ] && have pkg; then echo pkg; return; fi
    for pm in apt-get dnf yum zypper pacman apk xbps-install emerge; do
        if have "$pm"; then echo "$pm"; return; fi
    done
    echo none
}

# pkg_name <pm> <need>: package providing a need ("-" = part of the base system)
pkg_name() {
    case $1:$2 in
        apt-get:ssh|apk:ssh)              echo openssh-client ;;
        dnf:ssh|yum:ssh|zypper:ssh)       echo openssh-clients ;;
        pacman:ssh|xbps-install:ssh)      echo openssh ;;
        emerge:ssh)                       echo net-misc/openssh ;;
        pkg:ssh)                          echo - ;;
        emerge:bash)                      echo app-shells/bash ;;
        emerge:waypipe)                   echo gui-apps/waypipe ;;
        *:*)                              echo "$2" ;;      # bash, waypipe
    esac
}

install_packages() {
    needs=''
    have bash    || needs="$needs bash"
    have ssh     || needs="$needs ssh"
    have waypipe || needs="$needs waypipe"
    if [ -z "$needs" ]; then
        log "bash, ssh and waypipe are already installed"
        return
    fi
    pm=$(detect_pm)
    if [ "$pm" = none ]; then
        warn "no supported package manager found; install these yourself:$needs"
        return
    fi
    pkgs=''
    for need in $needs; do
        p=$(pkg_name "$pm" "$need")
        [ "$p" = - ] || pkgs="$pkgs $p"
    done
    [ -n "$pkgs" ] || return 0
    log "Installing with $pm:$pkgs"
    # shellcheck disable=SC2086  # word splitting of $pkgs is intended
    case $pm in
        apt-get)      as_root apt-get update -q
                      as_root env DEBIAN_FRONTEND=noninteractive \
                          apt-get install -y --no-install-recommends $pkgs ;;
        dnf|yum)      as_root "$pm" install -y $pkgs ;;
        zypper)       as_root zypper --non-interactive install --no-recommends $pkgs ;;
        pacman)       as_root pacman -S --needed --noconfirm $pkgs ;;
        apk)          as_root apk add $pkgs ;;
        xbps-install) as_root xbps-install -Sy $pkgs ;;
        emerge)       as_root emerge --noreplace $pkgs ;;
        pkg)          as_root pkg install -y $pkgs ;;
    esac
}

# check_path: warn if the 'saypipe' found on PATH isn't the one installed.
check_path() {
    found=$(command -v saypipe || true)
    if [ -z "$found" ] || [ "$(resolve "$found")" != "$(resolve "$DEST")" ]; then
        warn "'saypipe' on your PATH is ${found:-missing}, not $DEST" \
             "(another copy comes first, or ${DEST%/*} is not in PATH)"
    fi
}

# completion_dests: "<file in completions/> <destination>" lines. System-wide
# installs use the directories bash-completion, zsh and fish search under
# /usr/local/share; per-user installs use the user's own directories.
completion_dests() {
    if [ "$MODE" = user ]; then
        _ch=$(user_home)
        _cd=${XDG_DATA_HOME:-$_ch/.local/share}
        echo "saypipe.bash $_cd/bash-completion/completions/saypipe"
        echo "_saypipe $_cd/zsh/site-functions/_saypipe"
        echo "saypipe.fish ${XDG_CONFIG_HOME:-$_ch/.config}/fish/completions/saypipe.fish"
    else
        _cd=${PREFIX:-/usr/local}/share
        echo "saypipe.bash $_cd/bash-completion/completions/saypipe"
        echo "_saypipe $_cd/zsh/site-functions/_saypipe"
        # Some fish builds (e.g. Debian's) don't search /usr/local/share;
        # every fish searches /etc/fish/completions.
        _cf=$_cd/fish/vendor_completions.d
        if [ "${PREFIX:-/usr/local}" = /usr/local ] && have fish &&
           ! fish -c "contains -- $_cf \$fish_complete_path" >/dev/null 2>&1; then
            _cf=/etc/fish/completions
        fi
        echo "saypipe.fish $_cf/saypipe.fish"
    fi
}

# is_our_completion <file>: a saypipe completion script, or a dangling link
# to one (so we never overwrite or delete anything else).
is_our_completion() {
    if [ -L "$1" ] && [ ! -e "$1" ]; then
        case $(readlink -- "$1") in */completions/saypipe.bash|*/completions/_saypipe|*/completions/saypipe.fish) return 0 ;; esac
        return 1
    fi
    [ -f "$1" ] && grep -q 'completion for saypipe' "$1"
}

install_completions() {
    [ -d "$SRC_DIR/completions" ] || { warn "completions/ not found; skipping shell completion"; return 0; }
    destinations=$(completion_dests) || die "cannot determine completion destinations"
    while read -r src dst; do
        [ -f "$SRC_DIR/completions/$src" ] || continue
        if { [ -e "$dst" ] || [ -L "$dst" ]; } && ! is_our_completion "$dst"; then
            warn "$dst exists and is not saypipe's; not replacing it"; continue
        fi
        if [ "$MODE" = user ]; then
            mkdir -p "${dst%/*}" || die "cannot create completion directory ${dst%/*}"
            ln -sf -- "$(resolve "$SRC_DIR/completions/$src")" "$dst" ||
                die "failed to install completion $dst"
        else
            as_root mkdir -p "${dst%/*}" || die "cannot create completion directory ${dst%/*}"
            install_copy "$SRC_DIR/completions/$src" "$dst" 0644
        fi
        log "Installed completion: $dst"
    done <<EOF
$destinations
EOF
    if [ "$MODE" = user ] && have zsh; then
        echo "    zsh: if completion doesn't load, add this to ~/.zshrc before compinit:"
        echo "      fpath=(${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions \$fpath)"
    fi
}

uninstall_completions() {
    destinations=$({
        completion_dests
        # the fish location depends on the fish installed; check both
        [ "$MODE" = user ] || printf '%s\n' \
            "saypipe.fish ${PREFIX:-/usr/local}/share/fish/vendor_completions.d/saypipe.fish"
        if [ "$MODE" != user ] && [ "${PREFIX:-/usr/local}" = /usr/local ]; then
            printf '%s\n' "saypipe.fish /etc/fish/completions/saypipe.fish"
        fi
    }) || die "cannot determine completion destinations"
    while read -r src dst; do
        if is_our_completion "$dst"; then
            if [ "$MODE" = user ]; then rm -f -- "$dst"; else as_root rm -f -- "$dst"; fi ||
                die "failed to remove completion $dst"
            log "Removed completion: $dst"
        fi
    done <<EOF
$destinations
EOF
}

do_install() {
    [ -f "$SRC" ] || die "saypipe not found next to install.sh ($SRC_DIR)"
    install_packages
    check_bash
    have ssh || die "ssh is required but still not installed"
    have waypipe || warn "waypipe is not installed; saypipe needs it to launch apps"

    if [ "$MODE" = user ]; then
        target=$(resolve "$SRC")
        mkdir -p "${DEST%/*}"
        if [ -L "$DEST" ] && [ "$(resolve "$DEST")" = "$target" ]; then
            log "Already linked: $DEST -> $target"
        elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
            is_saypipe "$DEST" || die "$DEST exists and is not saypipe; not replacing it"
            ln -sf -- "$target" "$DEST" || die "failed to link $DEST"
            log "Linked $DEST -> $target (replaced the old one)"
        else
            ln -s -- "$target" "$DEST" || die "failed to link $DEST"
            log "Linked $DEST -> $target"
        fi
    else
        if { [ -e "$DEST" ] || [ -L "$DEST" ]; } && ! is_saypipe "$DEST"; then
            die "$DEST exists and is not saypipe; not overwriting it"
        fi
        log "Installing $DEST"
        as_root mkdir -p "${DEST%/*}"
        install_copy "$SRC" "$DEST" 0755
    fi
    "$DEST" --help >/dev/null 2>&1 || die "$DEST does not run"
    install_completions
    check_path
    cat <<EOF

Done. Next steps:
  saypipe <host> <command>          launch an app, e.g. saypipe myvm foot
  saypipe --host-add <host>         enable a host (checks it has waypipe)
  saypipe --probe --apply <host>    test what it supports and turn that on
  saypipe --link-add <host>         make <host> a command in ~/.local/bin
  saypipe --help                    everything else
Remote hosts need waypipe installed.
EOF
}

do_uninstall() {
    home=$(user_home)
    if [ "$MODE" = user ] && [ -L "$DEST" ] && [ ! -e "$DEST" ]; then
        rm -f -- "$DEST" && log "Removed dangling link $DEST (its checkout is gone)"
    elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
        is_saypipe "$DEST" || die "$DEST is not saypipe; not removing it"
        target=$(resolve "$DEST")

        if [ "$PURGE" = 1 ]; then
            # Close saypipe's shared connections before their config goes.
            # shellcheck disable=SC2013 # host entries are whitespace-separated
            for h in $(sed -e 's/#.*//' "${XDG_CONFIG_HOME:-$home/.config}/saypipe/share-hosts" 2>/dev/null); do
                "$DEST" --share-exit "$h" || true
            done
        fi

        # Host links to this saypipe would dangle: remove them first (in user
        # mode they point through $DEST).
        n=0
        for f in "${SAYPIPE_BIN_DIR:-$home/.local/bin}"/*; do
            [ "$f" != "$DEST" ] || continue
            if [ -L "$f" ] && [ "$(resolve "$f")" = "$target" ]; then
                rm -f -- "$f" && log "Removed host link ${f##*/}" && n=$((n + 1))
            fi
        done
        [ $n -gt 0 ] || log "No host links to $DEST"

        log "Removing $DEST"
        if [ "$MODE" = user ]; then rm -f -- "$DEST"; else as_root rm -f -- "$DEST"; fi
    else
        log "saypipe is not installed at $DEST"
    fi
    uninstall_completions

    cfg=${XDG_CONFIG_HOME:-$home/.config}/saypipe
    state=${XDG_STATE_HOME:-$home/.local/state}/saypipe
    if [ "$PURGE" = 1 ]; then
        rm -rf -- "$cfg" "$state" && log "Deleted $cfg and $state"
    else
        echo
        echo "Packages were kept (other software may use them), and so were $cfg"
        echo "and $state. Use --uninstall --purge to delete those."
    fi
}

MODE=system ACTION=install PURGE=0
for arg in "$@"; do
    case $arg in
        --user)      MODE=user ;;
        --uninstall) ACTION=uninstall ;;
        --purge)     PURGE=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option: $arg" ;;
    esac
done
[ "$PURGE" = 0 ] || [ "$ACTION" = uninstall ] || die "--purge only goes with --uninstall"

if [ "$MODE" = user ]; then
    DEST=${SAYPIPE_BIN_DIR:-$(user_home)/.local/bin}/saypipe
else
    DEST=${PREFIX:-/usr/local}/bin/saypipe
fi

case $ACTION in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
