#!/bin/bash
# Install pnpm + Node.js v24 in the sandbox.
#
# pnpm's installer delegates to `pnpm setup --force` (non-interactive)
# and writes PNPM_HOME + PATH exports to ~/.zshrc. After install, we use
# pnpm itself as a Node version manager via `pnpm runtime set node 24 -g`,
# which downloads Node 24, links it into $PNPM_HOME/bin, and makes it the
# default `node` on PATH. Runs after omz so ~/.zshrc additions aren't
# clobbered by omz's rewrite.
set -Eeuo pipefail

# One source of truth for locating pnpm, used both for the "already
# installed?" check and for invoking it afterwards. pnpm ≥10 installs
# the CLI at $PNPM_HOME/bin/pnpm; older standalone installers used
# $PNPM_HOME/pnpm directly.
find_pnpm() {
    command -v pnpm 2>/dev/null && return 0
    local p
    for p in "$HOME/Library/pnpm/bin/pnpm" "$HOME/Library/pnpm/pnpm" \
             "$HOME/.local/share/pnpm/pnpm" "$HOME/.pnpm/pnpm"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

PNPM="$(find_pnpm || true)"
if [[ -z "$PNPM" ]]; then
    echo "Installing pnpm into sandbox..." >&2
    curl -fsSL https://get.pnpm.io/install.sh | sh -
    PNPM="$(find_pnpm || true)"
fi

[[ -n "$PNPM" ]] || { echo "pnpm not found after install" >&2; exit 1; }

export PNPM_HOME="$HOME/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac

# Node already provisioned by a previous session — skip the (network)
# call to pnpm entirely.
if command -v node >/dev/null 2>&1 || [[ -x "$PNPM_HOME/bin/node" ]]; then
    exit 0
fi

echo "Installing Node.js v24 via pnpm..." >&2
"$PNPM" runtime set node 24 -g

