#!/bin/bash
# Remove the transient 1Password service-account token when the session ends,
# so it never lingers in the workspace between sessions — the host re-stages it
# from your 1Password on the next launch (see qs's op_auto_inject).
#
# Runs from the EXIT trap installed by the qs launcher. Like its profile.d
# counterpart this is best-effort; it does not run if the terminal is closed
# outright (SIGHUP), in which case the next launch overwrites the stale token.
set -Eeuo pipefail

rm -f "${SHARED_WORKSPACE:?}/_quicksand/op-token" 2>/dev/null || true
