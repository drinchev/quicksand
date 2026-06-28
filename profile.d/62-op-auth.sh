#!/bin/bash
# Make the 1Password service-account token available to the session as
# OP_SERVICE_ACCOUNT_TOKEN, so `op read`/`op run` work for the user and for
# Claude. The token is staged by the host in _quicksand/op-token (fetched from
# your own 1Password by `qs op-auth` / on every launch — see qs's op_auto_inject)
# and never persists in the sandbox between sessions.
#
# Profile scripts are executed, not sourced, so we can't export into the
# session directly. Instead we ensure ~/.zshrc loads the token from the 0600
# file at shell start; the launcher sources ~/.zshrc for claude / one-off /
# piped sessions too, so this reaches every session kind. The token itself is
# never written into ~/.zshrc — only a line that reads the file.
#
# Idempotent: the managed block is appended once.
set -Eeuo pipefail

zshrc="$HOME/.zshrc"
marker="# quicksand: 1Password service-account token (managed)"
grep -qF "$marker" "$zshrc" 2>/dev/null && exit 0

cat >> "$zshrc" <<'EOF'

# quicksand: 1Password service-account token (managed)
[[ -r "$SHARED_WORKSPACE/_quicksand/op-token" ]] && \
    export OP_SERVICE_ACCOUNT_TOKEN="$(<"$SHARED_WORKSPACE/_quicksand/op-token")"
EOF
