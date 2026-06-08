#!/bin/bash
# Seed ~/.gitconfig with the host user's git identity (passed in by the
# launcher via QS_GIT_USER_NAME / QS_GIT_USER_EMAIL) and a workspace-scoped
# safe.directory glob.
#
# safe.directory is necessary because repos under the shared workspace are
# owned by the host user, and git refuses to operate on them when running
# as the sandbox user without that exemption.
#
# Idempotent: only writes if ~/.gitconfig is missing.
set -Eeuo pipefail

if [[ ! -f "$HOME/.gitconfig" ]]; then
    git config -f "$HOME/.gitconfig" user.name      "${QS_GIT_USER_NAME:-}"
    git config -f "$HOME/.gitconfig" user.email     "${QS_GIT_USER_EMAIL:-}"
    git config -f "$HOME/.gitconfig" safe.directory "${SHARED_WORKSPACE:-/Users/Shared}/*"
fi
