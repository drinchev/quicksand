#!/bin/bash
# Install Oh My Zsh in the sandbox, then sync host-provided custom
# themes/plugins from $SHARED_WORKSPACE/_quicksand/custom/oh-my-zsh/ into
# ~/.oh-my-zsh/custom/.
#
# `--unattended` sets RUNZSH=no, CHSH=no, OVERWRITE_CONFIRMATION=no — the
# three prompts that would otherwise hang or fail (no password for chsh,
# exec'd zsh would replace this script, .zshrc overwrite prompt).
set -Eeuo pipefail

if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    echo "Installing Oh My Zsh into sandbox..." >&2
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

STAGING="${SHARED_WORKSPACE:-/Users/Shared}/_quicksand/custom/oh-my-zsh"
if [[ -d "$STAGING" && -d "$HOME/.oh-my-zsh/custom" ]]; then
    /usr/bin/rsync --checksum --recursive --perms --times "$STAGING/" "$HOME/.oh-my-zsh/custom/"
fi
