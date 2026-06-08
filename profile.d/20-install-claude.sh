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

if command -v claude >/dev/null 2>&1; then
    exit 0
fi
for p in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
    [[ -x "$p" ]] && exit 0
done

echo "Installing claude code into sandbox..." >&2
curl -fsSL https://claude.ai/install.sh | bash
