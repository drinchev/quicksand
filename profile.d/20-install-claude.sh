#!/bin/bash
# Install Claude Code inside the sandbox.
#
# Done in-sandbox (rather than via host Homebrew) so each sandbox gets
# its own claude binary and state. No host pollution; uninstalling the
# sandbox uninstalls claude with it.
#
# The upstream installer drops the binary under one of:
#   $HOME/.local/bin/claude
#   $HOME/.claude/local/claude
# Both are on the sandbox $PATH (see qs launcher).
set -Eeuo pipefail
# shellcheck source=/dev/null
. "${SHARED_WORKSPACE:?}/_quicksand/profile.d/00-lib.sh"

claude_installed() {
    command -v claude >/dev/null 2>&1 && return 0
    local p
    for p in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
        [[ -x "$p" ]] && return 0
    done
    return 1
}

claude_installed && exit 0

# The binary is a few hundred MB. Let one session download it; the others
# skip instead of racing it into the same file.
if ! qs_try_lock install-claude; then
    echo "Claude Code is being installed by another session; it will be available in new sessions once that finishes." >&2
    exit 0
fi
# Another session may have finished while we were checking.
claude_installed && exit 0

echo "Installing claude code into sandbox..." >&2
curl -fsSL https://claude.ai/install.sh | bash
