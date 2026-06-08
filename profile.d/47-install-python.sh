#!/bin/bash
# Install uv and a managed Python 3.12 in the sandbox.
#
# Needed primarily by 48-install-gcloud.sh — macOS's system Python is
# stuck at 3.9 (PEP 604 `bytes | str` syntax in urllib3 requires 3.10+),
# so the gcloud SDK can no longer bootstrap with it.
#
# Both uv's installer and `uv python install` are non-interactive by
# default. uv writes a PATH update to ~/.zshrc, which is why this runs
# after 45-install-oh-my-zsh.sh (omz's --unattended rewrites .zshrc).
set -Eeuo pipefail

if ! command -v uv >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/uv" ]]; then
    echo "Installing uv into sandbox..." >&2
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

UV="$HOME/.local/bin/uv"
[[ -x "$UV" ]] || UV="$(command -v uv)"

if ! "$UV" python find 3.12 >/dev/null 2>&1; then
    echo "Installing Python 3.12 into sandbox..." >&2
    "$UV" python install 3.12
fi
