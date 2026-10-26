#!/usr/bin/env bash
# 1063-ipc-devices.sh - Print the running daemon's `devices.list` JSON.
# Same token/shim setup as 1063-ipc-status.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$(cygpath -u "$USERPROFILE")/ppcheck/1063-test10}"
APPDIR="$(cygpath -u "$LOCALAPPDATA")/com.hawkeyexb.ppass.desktop"
CONF="$APPDIR/config.toml"
[ -f "$CONF" ] || { echo "no config.toml at $CONF" >&2; exit 1; }

DATA_DIR=$(sed -n "s/^data_dir *= *[\"']\(.*\)[\"']$/\1/p" "$CONF" | sed 's/\\\\/\\/g')
[ -n "$DATA_DIR" ] || { echo "could not parse data_dir from $CONF" >&2; exit 1; }
DATA_DIR=$(cygpath -u "$DATA_DIR")
[ -f "$DATA_DIR/ipc.token" ] || { echo "no ipc.token at $DATA_DIR" >&2; exit 1; }
SOCK=$(sed -n 1p "$DATA_DIR/ipc.token" | tr -d '\r')
TOKEN=$(sed -n 2p "$DATA_DIR/ipc.token" | tr -d '\r')
export SOCK TOKEN

SHIM="$WORK/.shim"
mkdir -p "$SHIM"
if [ ! -x "$SHIM/python3" ]; then
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v python)" > "$SHIM/python3"
  chmod +x "$SHIM/python3"
fi
export PATH="$SHIM:$PATH"

# shellcheck source=/dev/null
source "$REPO_ROOT/tools/ipc-lib.sh"
ipc devices.list
