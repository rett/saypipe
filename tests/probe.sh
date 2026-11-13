#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")/.."
source tests/common.sh
app=$PWD/saypipe
export PROBE_CALLS=$TEST_ROOT/calls
cat > "$SAYPIPE_BIN_DIR/ssh" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$PROBE_CALLS"
case "$*" in *'-O exit'*) exit 0 ;; *'-fN'*) exit 0 ;; esac
case $TEST_SCENARIO in
 exit42) echo broken; exit 42 ;;
 garbage) echo garbage; exit 0 ;;
 missing) echo '@@saypipe-waypipe@@127|not installed'; exit 0 ;;
 bad-version) echo '@@saypipe-waypipe@@1|version failed'; exit 0 ;;
 connection) exit 255 ;;
 timeout) exec sleep 30 ;;
 *) printf 'login banner\n@@saypipe-waypipe@@0|custom dev build\nshell=/bin/sh\ntool=sh\ntool=dbus-run-session\ntool=xdg-desktop-portal\nportal=gtk.portal\n' ;;
esac
MOCK
chmod +x "$SAYPIPE_BIN_DIR/ssh"
for scenario in exit42 garbage missing bad-version connection; do
 export TEST_SCENARIO=$scenario
 if "$app" --host-add testhost > "$TEST_ROOT/out" 2> "$TEST_ROOT/err"; then exit 1; fi
 [ ! -f "$XDG_CONFIG_HOME/saypipe/hosts" ]
done
export TEST_SCENARIO=valid
"$app" --host-add testhost > "$TEST_ROOT/out"
grep -q 'enabled (custom dev build)' "$TEST_ROOT/out"
# Root-safe failure injection and parent-process exit propagation.
mkdir "$XDG_CONFIG_HOME/saypipe/share-hosts"
if "$app" --probe --apply testhost > "$TEST_ROOT/out" 2> "$TEST_ROOT/err"; then exit 1; fi
! grep -q 'connection sharing enabled' "$TEST_ROOT/out"
rmdir "$XDG_CONFIG_HOME/saypipe/share-hosts"
export TEST_SCENARIO=timeout
if SAYPIPE_PROBE_TIMEOUT=0.2 "$app" --probe testhost > "$TEST_ROOT/out" 2> "$TEST_ROOT/err"; then exit 1; fi
grep -q 'timed out' "$TEST_ROOT/err"
grep -q -- '-O exit' "$PROBE_CALLS"
[ -z "$(find "$TMPDIR" -name 'saypipe-probe.*' -print)" ]
# libpulse's fallback must accept any single matching library candidate.
mkdir -p "$TEST_ROOT/lib"
: > "$TEST_ROOT/lib/libpulse.so.0"
snippet=$(sed -n '/^    r=socket-only$/,/^    echo "\\$r"$/p' saypipe | sed 's/\\\$/\$/g')
[ -n "$snippet" ]
snippet=${snippet//\/usr\/lib/"$TEST_ROOT/lib"}
snippet=${snippet//\/usr\/local\/lib/"$TEST_ROOT/other"}
result=$(sh -c "$snippet")
[ "$result" = socket+libpulse ]
printf 'probe checks passed\n'
