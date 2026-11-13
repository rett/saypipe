#!/usr/bin/env bash
# Installer regression checks use only fixture paths and simulated dependencies.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL_BASH=$(command -v bash)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/saypipe-install.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
unset SUDO_USER DOAS_USER
export HOME=$TEST_ROOT/home
export XDG_CONFIG_HOME=$TEST_ROOT/config XDG_STATE_HOME=$TEST_ROOT/state
export XDG_DATA_HOME=$TEST_ROOT/data XDG_RUNTIME_DIR=$TEST_ROOT/runtime
export TMPDIR=$TEST_ROOT/tmp SAYPIPE_BIN_DIR=$TEST_ROOT/bin
export PREFIX=$TEST_ROOT/prefix
export TEST_CALLS=$TEST_ROOT/calls REAL_BASH TEST_ROOT
export TEST_REAL_TOOLS=$TEST_ROOT/real-tools
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" "$TEST_ROOT/tools" "$TEST_ROOT/source" "$TEST_REAL_TOOLS"
chmod 700 "$XDG_RUNTIME_DIR"
cp "$ROOT/install.sh" "$ROOT/saypipe" "$TEST_ROOT/source/"
cp -R "$ROOT/completions" "$TEST_ROOT/source/"

# A closed PATH prevents discovery of a real package or privilege command.
for command in sh dirname sed readlink realpath grep cut uname mkdir ln cp chmod mv rm cat sort env; do
    executable=$(command -v "$command")
    ln -s "$executable" "$TEST_ROOT/tools/$command"
done
cat > "$TEST_ROOT/tools/id" <<'EOF'
#!/bin/sh
printf '0\n'
EOF
cat > "$TEST_ROOT/tools/bash" <<'EOF'
#!/bin/sh
if [ "${TEST_OLD_BASH:-0}" = 1 ]; then exit 1; fi
exec "$REAL_BASH" "$@"
EOF
cat > "$TEST_ROOT/tools/ssh" <<'EOF'
#!/bin/sh
printf 'ssh\n' >> "$TEST_CALLS"
exit 99
EOF
cat > "$TEST_ROOT/tools/waypipe" <<'EOF'
#!/bin/sh
printf 'waypipe\n' >> "$TEST_CALLS"
exit 99
EOF
cat > "$TEST_ROOT/tools/fish" <<'EOF'
#!/bin/sh
printf 'fish\n' >> "$TEST_CALLS"
exit 1
EOF
for command in sudo doas apt-get dnf yum zypper pacman apk xbps-install emerge pkg; do
    cat > "$TEST_ROOT/tools/$command" <<'EOF'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$TEST_CALLS"
exit "${TEST_PACKAGE_STATUS:-99}"
EOF
done
for command in id bash ssh waypipe fish sudo doas apt-get dnf yum zypper pacman apk xbps-install emerge pkg; do
    chmod +x "$TEST_ROOT/tools/$command"
done
# Reject mutations outside the fixture even if an installer regression restores
# the /etc fallback for a custom PREFIX. Keep real utilities out of PATH.
for command in mkdir ln cp chmod mv rm; do
    executable=$(command -v "$command")
    ln -s "$executable" "$TEST_REAL_TOOLS/$command"
    rm "$TEST_ROOT/tools/$command"
    cat > "$TEST_ROOT/tools/$command" <<'EOF'
#!/bin/sh
for argument do
    case $argument in
        /*) case $argument in "$TEST_ROOT"|"$TEST_ROOT"/*) ;; *)
            printf 'refused mutation outside fixture: %s\n' "$argument" >&2
            exit 98 ;;
        esac ;;
    esac
done
case ${0##*/} in
    cp) failure=${TEST_FAIL_PATH:-} ;;
    rm) failure=${TEST_FAIL_REMOVE:-} ;;
    ln) failure=${TEST_FAIL_LINK:-} ;;
    *) failure='' ;;
esac
if [ -n "$failure" ]; then
    case "$*" in *"$failure"*) exit 42 ;; esac
fi
exec "$TEST_REAL_TOOLS/${0##*/}" "$@"
EOF
    chmod +x "$TEST_ROOT/tools/$command"
done
export PATH=$TEST_ROOT/tools

fail() { printf 'FAIL installer: %s\n' "$*" >&2; exit 1; }
run() { sh "$TEST_ROOT/source/install.sh" "$@" > "$TEST_ROOT/output" 2>&1; }
reject() { if run "$@"; then fail "unexpected success for $*"; fi; }
contains() { grep -q -- "$1" "$TEST_ROOT/output" || fail "missing diagnostic $1"; }

TEST_OLD_BASH=1 reject --user
contains '4.4 or newer'
[[ ! -e $SAYPIPE_BIN_DIR/saypipe && ! -e $XDG_DATA_HOME/bash-completion ]] || fail 'old Bash installed files'

# Even a package manager reporting success cannot hide a missing ssh client.
mv "$TEST_ROOT/tools/ssh" "$TEST_ROOT/ssh-stub"
TEST_PACKAGE_STATUS=0 reject --user
contains 'ssh is required'
[[ ! -e $SAYPIPE_BIN_DIR/saypipe ]] || fail 'missing ssh installed launcher'
mv "$TEST_ROOT/ssh-stub" "$TEST_ROOT/tools/ssh"
: > "$TEST_CALLS"

run --user
[[ -L $SAYPIPE_BIN_DIR/saypipe ]] || fail 'user launcher is not linked'
[[ -L $XDG_CONFIG_HOME/fish/completions/saypipe.fish ]] || fail 'user completion is not linked'
run --user
contains 'Already linked'
ln -s "$SAYPIPE_BIN_DIR/saypipe" "$SAYPIPE_BIN_DIR/example-host"
mkdir -p "$XDG_CONFIG_HOME/saypipe" "$XDG_STATE_HOME/saypipe"
printf 'saved\n' > "$XDG_CONFIG_HOME/saypipe/settings"
run --user --uninstall
[[ ! -L $SAYPIPE_BIN_DIR/example-host && ! -L $SAYPIPE_BIN_DIR/saypipe ]] || fail 'user uninstall left links'
[[ -f $XDG_CONFIG_HOME/saypipe/settings ]] || fail 'uninstall removed config without purge'
run --user --uninstall --purge
[[ ! -e $XDG_CONFIG_HOME/saypipe && ! -e $XDG_STATE_HOME/saypipe ]] || fail 'purge left config/state'

run
[[ -f $PREFIX/bin/saypipe && ! -L $PREFIX/bin/saypipe ]] || fail 'system launcher was not copied'
[[ -f $PREFIX/share/fish/vendor_completions.d/saypipe.fish ]] || fail 'custom PREFIX lost fish completion'
run --uninstall
[[ ! -e $PREFIX/bin/saypipe ]] || fail 'copied uninstall left launcher'

mkdir -p "$SAYPIPE_BIN_DIR"
printf 'unrelated\n' > "$SAYPIPE_BIN_DIR/saypipe"
reject --user
contains 'not replacing'
reject --user --uninstall
contains 'not removing'
[[ $(cat "$SAYPIPE_BIN_DIR/saypipe") == unrelated ]] || fail 'unrelated user launcher changed'
rm "$SAYPIPE_BIN_DIR/saypipe"
cp "$TEST_ROOT/source/saypipe" "$SAYPIPE_BIN_DIR/saypipe"
TEST_FAIL_LINK=$SAYPIPE_BIN_DIR/saypipe reject --user
contains 'failed to link'
[[ ! -L $SAYPIPE_BIN_DIR/saypipe ]] || fail 'failed link changed copied launcher'
run --user
[[ -L $SAYPIPE_BIN_DIR/saypipe ]] || fail 'user install did not replace owned copied launcher'
run --user --uninstall

# A preexisting unrelated launcher and dangling system destination are protected.
printf 'unrelated\n' > "$PREFIX/bin/saypipe"
reject
contains 'not overwriting'
[[ $(cat "$PREFIX/bin/saypipe") == unrelated ]] || fail 'unrelated launcher changed'
reject --uninstall
contains 'not removing'
rm "$PREFIX/bin/saypipe"
ln -s "$TEST_ROOT/missing" "$PREFIX/bin/saypipe"
reject
contains 'not overwriting'
[[ -L $PREFIX/bin/saypipe ]] || fail 'dangling destination was replaced'
rm "$PREFIX/bin/saypipe"

# Completion installation and removal errors must survive later destinations.
# Failure injection works for root as well as an ordinary user.
TEST_FAIL_PATH=completions/saypipe.bash reject
contains 'failed to install'
if grep -q '^Done\.' "$TEST_ROOT/output"; then fail 'completion failure claimed success'; fi
for leftover in "$PREFIX/share/bash-completion/completions/saypipe.new."*; do
    [[ ! -e $leftover ]] || fail 'failed copy left staging directory'
done
run
old_launcher=$(cat "$PREFIX/bin/saypipe")
TEST_FAIL_PATH=source/saypipe reject
contains 'failed to install'
[[ $(cat "$PREFIX/bin/saypipe") == "$old_launcher" ]] || fail 'failed copy replaced launcher'
TEST_FAIL_REMOVE=bash-completion/completions/saypipe reject --uninstall
contains 'failed to remove completion'
run --uninstall

# Copying over an owned completion symlink must leave its old target intact.
mkdir -p "$PREFIX/share/bash-completion/completions"
printf '# completion for saypipe\nsentinel\n' > "$TEST_ROOT/old-completion"
ln -s "$TEST_ROOT/old-completion" "$PREFIX/share/bash-completion/completions/saypipe"
run
[[ ! -L $PREFIX/share/bash-completion/completions/saypipe ]] || fail 'completion copy followed symlink'
grep -q '^sentinel$' "$TEST_ROOT/old-completion" || fail 'completion target overwritten'
run --uninstall

# Preserve unrelated completion files in both layouts.
printf 'unrelated\n' > "$PREFIX/share/bash-completion/completions/saypipe"
run
run --uninstall
[[ $(cat "$PREFIX/share/bash-completion/completions/saypipe") == unrelated ]] || fail 'unrelated system completion changed'
mkdir -p "$XDG_DATA_HOME/bash-completion/completions"
printf 'unrelated\n' > "$XDG_DATA_HOME/bash-completion/completions/saypipe"
run --user
run --user --uninstall
[[ $(cat "$XDG_DATA_HOME/bash-completion/completions/saypipe") == unrelated ]] || fail 'unrelated user completion changed'
rm "$XDG_DATA_HOME/bash-completion/completions/saypipe"

# The linked checkout can disappear before uninstall, including completions.
run --user
mv "$TEST_ROOT/source/saypipe" "$TEST_ROOT/source/saved-launcher"
mv "$TEST_ROOT/source/completions" "$TEST_ROOT/source/saved-completions"
run --user --uninstall
[[ ! -L $SAYPIPE_BIN_DIR/saypipe && ! -L $XDG_CONFIG_HOME/fish/completions/saypipe.fish ]] || fail 'dangling owned links remain'
mv "$TEST_ROOT/source/saved-launcher" "$TEST_ROOT/source/saypipe"
mv "$TEST_ROOT/source/saved-completions" "$TEST_ROOT/source/completions"

# Purge dispatches only through the fake ssh and removes fixture-owned paths.
run --user
mkdir -p "$XDG_CONFIG_HOME/saypipe" "$XDG_STATE_HOME/saypipe"
printf 'example-host\n' > "$XDG_CONFIG_HOME/saypipe/share-hosts"
run --user --uninstall --purge
[[ ! -e $XDG_CONFIG_HOME/saypipe && ! -e $XDG_STATE_HOME/saypipe ]] || fail 'active purge left config/state'
grep -q '^ssh$' "$TEST_CALLS" || fail 'purge did not attempt shared-connection cleanup'
: > "$TEST_CALLS"

# The default system prefix still supports fish's system fallback. Inspect the
# destination generator without executing an install into any system directory.
sed '/^MODE=system ACTION=install PURGE=0/,$d' "$TEST_ROOT/source/install.sh" > "$TEST_ROOT/destinations.sh"
# shellcheck disable=SC2016 # evaluated by the isolated child shell
env PREFIX=/usr/local sh -c '. "$1"; MODE=system; completion_dests' sh "$TEST_ROOT/destinations.sh" > "$TEST_ROOT/destinations"
grep -q '^saypipe.fish /etc/fish/completions/saypipe.fish$' "$TEST_ROOT/destinations" || fail 'default fish fallback changed'
[[ $(cat "$TEST_CALLS") == fish ]] || fail 'unexpected dependency or privilege command ran'
printf 'PASS installer isolated install/uninstall checks\n'
