#!/bin/bash
# Install Oh My Zsh inside the sandbox.
#
# The official one-liner from https://ohmyz.sh, plus `--unattended` (which
# the upstream installer translates to RUNZSH=no, CHSH=no,
# OVERWRITE_CONFIRMATION=no). Without --unattended the installer:
#   - prompts "overwrite .zshrc? [Y/n]"
#   - runs `chsh` (would prompt for a password — we don't have one)
#   - exec's into zsh at the end (would replace this profile.d script)
# All three break unattended runs.
#
# Idempotent guard: the installer drops a marker directory at
# ~/.oh-my-zsh, so we check for that before doing anything.
set -Eeuo pipefail

if [[ -d "$HOME/.oh-my-zsh" ]]; then
    exit 0
fi

echo "Installing Oh My Zsh into sandbox..." >&2
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
