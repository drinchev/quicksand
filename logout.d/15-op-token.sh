#!/bin/bash
# Remove the transient 1Password service-account token when the LAST session
# of this sandbox ends, so it never lingers in the workspace between
# sessions — the host re-stages it from your 1Password on the next launch
# (libexec/qs-auth-op), or on the next SSH login via the credential broker.
#
# "Last" matters: sessions overlap (a local `qs claude` beside an SSH login,
# or the several short logins an SSH client makes while a long one is
# running), and removing the token under a live session leaves every shell
# it starts afterwards without credentials. Sessions record themselves in
# _quicksand/sessions/ (profile.d/05-session-register.sh); this drops our
# own record, prunes records whose process is gone, and keeps the token if
# any session is left.
#
# Runs from the EXIT trap installed by the session launcher. Like its
# profile.d counterpart this is best-effort; it does not run if the terminal
# is closed outright (SIGHUP), in which case a later session's exit — or the
# next launch overwriting the stale token — takes care of it.
set -Eeuo pipefail

SESSIONS_DIR="${SHARED_WORKSPACE:?}/_quicksand/sessions"
rm -f "$SESSIONS_DIR/$PPID" 2>/dev/null || true
for record in "$SESSIONS_DIR"/*; do
    [[ -e "$record" ]] || continue
    pid="${record##*/}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$record" 2>/dev/null || true
done

rm -f "$SHARED_WORKSPACE/_quicksand/op-token" 2>/dev/null || true
