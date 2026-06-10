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

# Disable omz's automatic terminal/tab title. Its termsupport library
# re-asserts the title on every prompt, which would clobber a title you
# set by hand (e.g. printf '\e]0;my tab\a'). The installer's default
# .zshrc ships this setting commented out, so uncomment it; if it isn't
# present (e.g. a hand-edited .zshrc), append it. Runs every session — not
# just on first install — so existing sandboxes pick it up too. Idempotent.
ZSHRC="$HOME/.zshrc"
if [[ -f "$ZSHRC" ]] && ! grep -q '^[[:space:]]*DISABLE_AUTO_TITLE="true"' "$ZSHRC"; then
    if grep -q '^[[:space:]]*#[[:space:]]*DISABLE_AUTO_TITLE="true"' "$ZSHRC"; then
        sed -i '' 's/^[[:space:]]*#[[:space:]]*DISABLE_AUTO_TITLE="true"/DISABLE_AUTO_TITLE="true"/' "$ZSHRC"
    else
        printf '\nDISABLE_AUTO_TITLE="true"\n' >> "$ZSHRC"
    fi
fi
