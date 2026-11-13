#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")/.."
source tests/common.sh
app=$PWD/saypipe
if ! command -v python3 >/dev/null 2>&1; then
    printf 'skip: audio socket fixture requires python3\n'; exit 0
fi
mkdir -p "$XDG_CONFIG_HOME/saypipe" "$XDG_RUNTIME_DIR/pulse"
printf 'testhost\n' > "$XDG_CONFIG_HOME/saypipe/audio-hosts"
python3 - "$XDG_RUNTIME_DIR/pulse/native" <<'PY' &
import socket,sys,time
sock=socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
time.sleep(30)
PY
socket_pid=$!
trap 'kill "$socket_pid" 2>/dev/null || true; wait "$socket_pid" 2>/dev/null || true; rm -rf -- "$TEST_ROOT"' EXIT
for n in {1..100}; do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/pulse/native" ]
export AUDIO_CALLS=$TEST_ROOT/calls
cat > "$SAYPIPE_BIN_DIR/ssh" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$AUDIO_CALLS"
exit 0
MOCK
cat > "$SAYPIPE_BIN_DIR/waypipe" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$AUDIO_CALLS"
[ "${TEST_HOLD:-0}" = 0 ] || exec sleep 30
while [ "$1" != ssh ]; do shift; done
shift
while [ "$1" = -o ] || [ "$1" = -R ]; do shift; shift; done
shift
exec /bin/sh -c "$*"
MOCK
cat > "$SAYPIPE_BIN_DIR/dbus-run-session" <<'MOCK'
#!/bin/sh
shift
exec "$@"
MOCK
chmod +x "$SAYPIPE_BIN_DIR/ssh" "$SAYPIPE_BIN_DIR/waypipe" "$SAYPIPE_BIN_DIR/dbus-run-session"
audio_command=$(cat <<'REMOTE'
sh -c 'printf "%s" "$PULSE_SERVER"'
REMOTE
)
"$app" --foreground testhost "$audio_command" > "$TEST_ROOT/out"
grep -q '^unix:/tmp/saypipe-pulse-' "$TEST_ROOT/out"
grep -q -- '-R /tmp/saypipe-pulse-' "$AUDIO_CALLS"
grep -q -- '-O cancel' "$AUDIO_CALLS"
grep -q -- 'rm -f -- /tmp/saypipe-pulse-' "$AUDIO_CALLS"
: > "$AUDIO_CALLS"
TEST_HOLD=1 "$app" --run testhost app & worker=$!
sleep 0.3
kill -TERM "$worker"
wait "$worker" && exit 1
grep -q -- '-O cancel' "$AUDIO_CALLS"
printf 'audio forwarding checks passed\n'
