#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")/.."
source tests/common.sh
app=$PWD/saypipe
[ "$("$app" --version)" = "saypipe $(cat VERSION)" ]
mkdir "$TEST_ROOT/copy"
cp "$app" "$TEST_ROOT/copy/saypipe"
[ "$("$TEST_ROOT/copy/saypipe" --version)" = "$("$app" --version)" ]
cat > "$SAYPIPE_BIN_DIR/ssh" <<'MOCK'
#!/bin/sh
[ "$1" = -V ] || exit 99
printf 'OpenSSH fixture\n'
MOCK
cat > "$SAYPIPE_BIN_DIR/waypipe" <<'MOCK'
#!/bin/sh
[ "$1" = --version ] || exit 99
printf 'waypipe fixture\n'
MOCK
chmod +x "$SAYPIPE_BIN_DIR/ssh" "$SAYPIPE_BIN_DIR/waypipe"
mkdir -p "$XDG_CONFIG_HOME/saypipe"
printf 'testhost\n' > "$XDG_CONFIG_HOME/saypipe/hosts"
before=$(cksum "$XDG_CONFIG_HOME/saypipe/hosts")
if WAYLAND_DISPLAY=missing SECRET_TOKEN=never-print-this "$app" --doctor > "$TEST_ROOT/out"; then exit 1; fi
grep -q 'display.*missing' "$TEST_ROOT/out"
grep -q 'OpenSSH fixture' "$TEST_ROOT/out"
! grep -q never-print-this "$TEST_ROOT/out"
[ "$(cksum "$XDG_CONFIG_HOME/saypipe/hosts")" = "$before" ]
for option in --version --doctor; do
 actual=0; "$app" "$option" unexpected >/dev/null 2>&1 || actual=$?
 [ "$actual" -eq 2 ]
done
printf 'diagnostic checks passed\n'
