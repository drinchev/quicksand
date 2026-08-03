#!/bin/bash
# Install the qs-docker client onto the sandbox PATH when this sandbox has
# a host docker broker (see `qs docker` / config/qs-docker-broker). The
# client is staged into _quicksand/bin/ by `qs docker NAME`; absence means
# the feature is off for this sandbox — do nothing.
#
# Idempotent: cp only when the staged copy differs.
set -Eeuo pipefail

SHIM_SRC="$SHARED_WORKSPACE/_quicksand/bin/qs-docker"
SHIM_DEST="$HOME/.local/bin/qs-docker"
# Staged copy gone ('qs docker NAME off') — drop the installed client too.
[[ -f "$SHIM_SRC" ]] || { rm -f "$SHIM_DEST"; exit 0; }

cmp -s "$SHIM_SRC" "$SHIM_DEST" 2>/dev/null && exit 0
mkdir -p "$HOME/.local/bin"
cp "$SHIM_SRC" "$SHIM_DEST"
chmod 0755 "$SHIM_DEST"
echo "quicksand: qs-docker installed — containers run on the host engine via the qs broker" >&2
