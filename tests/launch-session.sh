#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise the worker through a fake waypipe/SSH transport and remote PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir=$PWD
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
export XDG_CONFIG_HOME=$test_dir/config XDG_STATE_HOME=$test_dir/state
export TEST_OUTPUT=$test_dir/output TEST_BUS_STARTS=$test_dir/bus-starts
export TEST_REMOTE_BIN=$test_dir/remote
mkdir -p "$test_dir/local" "$TEST_REMOTE_BIN"
ln -s /bin/sh "$TEST_REMOTE_BIN/sh"
cat > "$test_dir/local/waypipe" <<'MOCK'
#!/bin/sh
while [ "$1" != ssh ]; do shift; done
shift
shift # host (these tests have no sharing or audio forwarding)
SHELL=${TEST_REMOTE_SHELL:-/bin/sh} PATH=$TEST_REMOTE_BIN exec /bin/sh -c "$*"
MOCK
chmod +x "$test_dir/local/waypipe"
export PATH=$test_dir/local:$PATH

# Keep the remote login shell's command syntax, with or without a private bus.
bash_command='items=(one "two three"); printf "%s" "${items[1]}" > "$TEST_OUTPUT"'
TEST_REMOTE_SHELL=$(command -v bash) "$project_dir/saypipe" --run testhost "$bash_command"
[ "$(cat "$TEST_OUTPUT")" = 'two three' ]

# With no remote dbus-run-session, preserve shell evaluation and exit status.
"$project_dir/saypipe" --run testhost 'printf "%s" "fallback" > "$TEST_OUTPUT"'
[ "$(cat "$TEST_OUTPUT")" = fallback ]

cat > "$TEST_REMOTE_BIN/dbus-run-session" <<'MOCK'
#!/bin/sh
[ "$1" = -- ] || exit 99
shift
printf 'start\n' >> "$TEST_BUS_STARTS"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/private-test-bus
exec "$@"
MOCK
chmod +x "$TEST_REMOTE_BIN/dbus-run-session"

"$project_dir/saypipe" --run testhost 'printf "%s" "$DBUS_SESSION_BUS_ADDRESS" > "$TEST_OUTPUT"'
[ "$(cat "$TEST_OUTPUT")" = unix:path=/private-test-bus ]

# Quotes, metacharacters, a pipeline and newlines stay inside the private bus.
"$project_dir/saypipe" --run testhost "printf '%s\\n' \"a'b \\\$x; literal\" | { read -r value; printf '%s' \"\$value\" > \"\$TEST_OUTPUT\"; }"
[ "$(cat "$TEST_OUTPUT")" = "a'b \$x; literal" ]
"$project_dir/saypipe" --run testhost $'printf first > "$TEST_OUTPUT"\nprintf second >> "$TEST_OUTPUT"'
[ "$(cat "$TEST_OUTPUT")" = firstsecond ]

TEST_REMOTE_SHELL=$(command -v bash) "$project_dir/saypipe" --run testhost "$bash_command"
[ "$(cat "$TEST_OUTPUT")" = 'two three' ]

# Configured defaults take the same path through the public command entry.
mkdir -p "$XDG_CONFIG_HOME/saypipe"
printf '%s\n' 'testhost printf default > "$TEST_OUTPUT"' > "$XDG_CONFIG_HOME/saypipe/commands"
SAYPIPE_WAIT=2 "$project_dir/saypipe" testhost
[ "$(cat "$TEST_OUTPUT")" = default ]

for expected in 1 126 127; do
    actual=0
    "$project_dir/saypipe" --run testhost "exit $expected" || actual=$?
    [ "$actual" = "$expected" ]
done
[ "$(wc -l < "$TEST_BUS_STARTS")" -eq 8 ]
grep -q 'exit 127' "$XDG_STATE_HOME/saypipe/errors.log"
# When installed, exercise two real session buses through the worker too.
real_dbus=$(command -v dbus-run-session || true)
if [ -n "$real_dbus" ]; then
    ln -s "$(command -v dbus-daemon)" "$TEST_REMOTE_BIN/dbus-daemon"
    rm "$TEST_REMOTE_BIN/dbus-run-session"
    ln -s "$real_dbus" "$TEST_REMOTE_BIN/dbus-run-session"
    "$project_dir/saypipe" --run testhost 'printf "%s" "$DBUS_SESSION_BUS_ADDRESS" > "$TEST_OUTPUT.1"' &
    first=$!
    "$project_dir/saypipe" --run testhost 'printf "%s" "$DBUS_SESSION_BUS_ADDRESS" > "$TEST_OUTPUT.2"' &
    second=$!
    wait "$first"
    wait "$second"
    [ -s "$TEST_OUTPUT.1" ] && [ -s "$TEST_OUTPUT.2" ]
    [ "$(cat "$TEST_OUTPUT.1")" != "$(cat "$TEST_OUTPUT.2")" ]
else
    printf '%s\n' 'skip: real private buses (dbus-run-session unavailable)'
fi
printf '%s\n' 'launch session checks passed'
