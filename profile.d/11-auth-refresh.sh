#!/bin/bash
# Keep host-staged credentials working in sessions the host didn't start.
#
#   1. Install the qs-auth-refresh client onto the sandbox PATH
#      (~/.local/bin). The build stages it into _quicksand/bin/ from
#      config/qs-auth-refresh; Quicksand.app answers it on the host
#      (app/Sources/QuicksandCore/AuthBroker.swift). Anyone in the sandbox can run it when a
#      credential has gone stale — a GCP token lasts about an hour.
#   2. For an SSH session, run it now. `qs shell` / `qs claude` refresh
#      credentials on the host before entering, so local sessions skip
#      this; an SSH login (`qs ssh-auth`) has no such step, and without
#      it would start with an expired GCP token and no 1Password token.
#
# Runs before ~/.zshrc is sourced, so a 1Password token staged here is
# exported into the session like any other. Best-effort: a host that
# can't answer costs a warning on stderr, never the session.
set -Eeuo pipefail

SRC="${SHARED_WORKSPACE:?}/_quicksand/bin/qs-auth-refresh"
DEST="$HOME/.local/bin/qs-auth-refresh"
# Not staged (the build predates the broker) — nothing to install or call.
[[ -f "$SRC" ]] || exit 0

if ! cmp -s "$SRC" "$DEST" 2>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    cp "$SRC" "$DEST"
    chmod 0755 "$DEST"
fi

[[ -n "${SSH_CONNECTION:-}" ]] || exit 0
"$DEST" </dev/null >&2 || true
