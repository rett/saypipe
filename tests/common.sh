#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Source from test scripts to confine all application state and commands.
set -euo pipefail
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/saypipe-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export HOME=$TEST_ROOT/home
export XDG_CONFIG_HOME=$TEST_ROOT/config XDG_STATE_HOME=$TEST_ROOT/state
export XDG_DATA_HOME=$TEST_ROOT/data XDG_RUNTIME_DIR=$TEST_ROOT/run
export SAYPIPE_BIN_DIR=$TEST_ROOT/bin TMPDIR=$TEST_ROOT/tmp
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$SAYPIPE_BIN_DIR" "$TMPDIR"
export PATH=$SAYPIPE_BIN_DIR:$PATH
cat > "$SAYPIPE_BIN_DIR/ssh" <<'MOCK'
#!/bin/sh
echo 'test tried an unstubbed SSH command' >&2
exit 99
MOCK
chmod +x "$SAYPIPE_BIN_DIR/ssh"
