#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")/.."
source tests/common.sh
app=$PWD/saypipe
cfg=$XDG_CONFIG_HOME/saypipe
mkdir -p "$cfg"
pids=()
for n in {1..40}; do "$app" --default-set --global "command$n" >/dev/null & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done
[ "$(grep -c '^\* ' "$cfg/commands")" -eq 1 ]
pids=()
for n in {1..40}; do "$app" --host-add --force "host$n" >/dev/null & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done
[ "$(grep -c '^host' "$cfg/hosts")" -eq 40 ]
# Atomic replacement must update the symlink target, preserving private mode.
mv "$cfg/commands" "$TEST_ROOT/commands"
chmod 600 "$TEST_ROOT/commands"
ln -s "$TEST_ROOT/commands" "$cfg/commands"
"$app" --default-set --global changed >/dev/null
[ -L "$cfg/commands" ]
[ "$(awk '$1 == "*" {print $2}' "$TEST_ROOT/commands")" = changed ]
[ "$(ls -l "$TEST_ROOT/commands" | cut -c1-10)" = '-rw-------' ]
# Invalid targets cannot be mistaken for a successful write, even as root.
mkdir "$cfg/gpu-hosts"
if "$app" --gpu-add host1 > "$TEST_ROOT/out" 2> "$TEST_ROOT/err"; then exit 1; fi
! grep -q 'GPU enabled' "$TEST_ROOT/out"
rmdir "$cfg/gpu-hosts"
# An inherited user@host entry is never silently removed.
printf 'plain\n' > "$cfg/hosts"
if "$app" --host-remove user@plain > "$TEST_ROOT/out" 2> "$TEST_ROOT/err"; then exit 1; fi
grep -q 'plain' "$cfg/hosts"
printf 'plain printf inherited\nuser@plain printf exact\n' > "$cfg/commands"
# Check selection via a transport shim and foreground worker.
cat > "$SAYPIPE_BIN_DIR/waypipe" <<'MOCK'
#!/bin/sh
while [ "$1" != ssh ]; do shift; done
shift; shift
exec /bin/sh -c "$*"
MOCK
chmod +x "$SAYPIPE_BIN_DIR/waypipe"
cat > "$SAYPIPE_BIN_DIR/dbus-run-session" <<'MOCK'
#!/bin/sh
shift
exec "$@"
MOCK
chmod +x "$SAYPIPE_BIN_DIR/dbus-run-session"
"$app" --foreground user@plain > "$TEST_ROOT/command"
[ "$(cat "$TEST_ROOT/command")" = exact ]
# Exact/inherited removals preserve shared entries for all option lists.
for kind in gpu audio share; do
    printf 'plain\n' > "$cfg/$kind-hosts"
    if "$app" "--$kind-remove" user@plain >/dev/null 2>&1; then exit 1; fi
    [ "$(cat "$cfg/$kind-hosts")" = plain ]
    printf 'user@plain\n' >> "$cfg/$kind-hosts"
    "$app" "--$kind-remove" user@plain >/dev/null
    [ "$(cat "$cfg/$kind-hosts")" = plain ]
done
printf 'plain inherited\n' > "$cfg/commands"
if "$app" --default-remove user@plain >/dev/null 2>&1; then exit 1; fi
printf 'user@plain exact\n' >> "$cfg/commands"
"$app" --default-remove user@plain >/dev/null
[ "$(cat "$cfg/commands")" = 'plain inherited' ]

# Stale locks owned by a dead process on this machine are recoverable.
mkdir "$cfg/.lock"
printf '%s %s\n' "$(uname -n)" 99999999 > "$cfg/.lock/owner"
"$app" --default-set --global recovered >/dev/null
[ ! -d "$cfg/.lock" ]
for invalid in @host user@ a@b@c; do
 if "$app" --host-add --force "$invalid" >/dev/null 2>&1; then exit 1; fi
done
# A lock's EXIT handler must run the cleanup callback it temporarily replaced.
(
    source <(sed '/^# Internal: the detached worker/,$d' "$app")
    prior_cleanup() { : > "$TEST_ROOT/chained-exit"; }
    trap prior_cleanup EXIT
    config_lock
    kill -TERM "$BASHPID"
) && exit 1
[ -f "$TEST_ROOT/chained-exit" ]
[ ! -d "$cfg/.lock" ]
printf 'configuration checks passed\n'
