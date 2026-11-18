#!/bin/bash
# Record that a session is running in this sandbox, so a session that ends
# can tell whether it was the last one (see logout.d/15-op-token.sh, which
# must not remove a credential other sessions are still using).
#
# The record is an empty file named after the session shell's PID — the
# shell that runs these hooks, hence $PPID here and in the logout hook. A
# session that dies without running its logout hooks leaves its file
# behind; readers check that the PID is still alive and drop it if not.
set -Eeuo pipefail

SESSIONS_DIR="${SHARED_WORKSPACE:?}/_quicksand/sessions"
mkdir -p "$SESSIONS_DIR"
: > "$SESSIONS_DIR/$PPID"
