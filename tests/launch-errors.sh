#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")/.."
source tests/common.sh
app=$PWD/saypipe
cat > "$SAYPIPE_BIN_DIR/waypipe" <<'MOCK'
#!/bin/sh
case $TEST_CASE in
 early) printf 'fatal: startup failed\n' >&2; exit 3 ;;
 delayed) sleep 0.4; printf 'fatal: transport failed\n' >&2; exit 1 ;;
 close) sleep 2; exit 1 ;;
 output) printf 'visible output\n'; exit 0 ;;
 flood) dd if=/dev/zero bs=4096 count=64 2>/dev/null | tr '\000' x; exit 3 ;;
 wait) [ -z "${WAIT_PID:-}" ] || printf '%s' "$$" > "$WAIT_PID"; exec sleep 30 ;;
esac
MOCK
chmod +x "$SAYPIPE_BIN_DIR/waypipe"
export TEST_CASE=early
if "$app" --foreground demo app > "$TEST_ROOT/out" 2>&1; then exit 1; fi
grep -q 'exit 3' "$XDG_STATE_HOME/saypipe/errors.log"
export TEST_CASE=delayed
SAYPIPE_WAIT=0 "$app" demo app
sleep 1
grep -q 'transport failed' "$XDG_STATE_HOME/saypipe/errors.log"
export TEST_CASE=close
before=$(wc -c < "$XDG_STATE_HOME/saypipe/errors.log")
SAYPIPE_STARTUP_WINDOW=0 "$app" --run demo app && exit 1
[ "$(wc -c < "$XDG_STATE_HOME/saypipe/errors.log")" -eq "$before" ]
export TEST_CASE=output
"$app" --foreground demo app > "$TEST_ROOT/out"
grep -q 'visible output' "$TEST_ROOT/out"
export TEST_CASE=flood
SAYPIPE_LOG_BYTES=4096 "$app" --run demo app && exit 1
[ "$(wc -c < "$XDG_STATE_HOME/saypipe/errors.log")" -lt 20000 ]
export TEST_CASE=wait
"$app" --run demo app & worker=$!
sleep 0.3
kill -TERM "$worker"
wait "$worker" && exit 1
[ -z "$(find "$TMPDIR" -name 'saypipe-session.*' -print)" ]
# The public foreground entry must forward TERM to the worker and transport.
export WAIT_PID=$TEST_ROOT/wait-pid
"$app" --foreground demo app & launcher=$!
for n in {1..100}; do [ -s "$WAIT_PID" ] && break; sleep 0.05; done
transport=$(cat "$WAIT_PID")
kill -TERM "$launcher"
wait "$launcher" && exit 1
! kill -0 "$transport" 2>/dev/null
# A detached startup watch owns only its status directory, not the app.
rm -f "$WAIT_PID"
SAYPIPE_WAIT=30 "$app" demo app & launcher=$!
for n in {1..100}; do [ -s "$WAIT_PID" ] && break; sleep 0.05; done
kill -TERM "$launcher"
wait "$launcher" && exit 1
[ -z "$(find "$TMPDIR" -name 'saypipe-status.*' -print)" ]
kill -TERM "$(cat "$WAIT_PID")"
sleep 0.2
printf 'launch error checks passed\n'
