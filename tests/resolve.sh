#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
cd "$(dirname "$0")/.."
source tests/common.sh
app=$PWD/saypipe
export TEST_REAL_READLINK
TEST_REAL_READLINK=$(command -v readlink)
# BSD readlink can support -f but refuse a nonexistent final component.
cat > "$SAYPIPE_BIN_DIR/readlink" <<'MOCK'
#!/bin/sh
if [ "$1" = -f ]; then
    [ "$3" = / ] && { printf '/\n'; exit 0; }
    exit 1
fi
exec "$TEST_REAL_READLINK" "$@"
MOCK
cat > "$SAYPIPE_BIN_DIR/realpath" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$SAYPIPE_BIN_DIR/readlink" "$SAYPIPE_BIN_DIR/realpath"
"$app" --default-set --global initial >/dev/null
grep -q '^\* initial$' "$XDG_CONFIG_HOME/saypipe/commands"
rm "$XDG_CONFIG_HOME/saypipe/commands"
ln -s "$TEST_ROOT/new-commands" "$XDG_CONFIG_HOME/saypipe/commands"
"$app" --default-set --global linked >/dev/null
[ -L "$XDG_CONFIG_HOME/saypipe/commands" ]
grep -q '^\* linked$' "$TEST_ROOT/new-commands"
printf 'portable path resolution checks passed\n'
