#!/bin/bash
# Name the tab "<sandbox> | <kind>", e.g. "work | Claude" or "work | Shell".
#
# QS_SESSION_KIND is set by the qs launcher only for the two interactive
# modes (Claude / Shell); it's blank for one-off command and piped sessions,
# so this no-ops there. Pairs with omz's DISABLE_AUTO_TITLE (enabled in
# 45-install-oh-my-zsh.sh) so the name isn't overwritten on the next prompt.
#
# OSC 0 (set icon name + window title) is a standard xterm escape honored by
# essentially every terminal, so — unlike the tab *color* (iTerm-only OSC 6)
# — this needs no iTerm guard, just a tty.
set -Eeuo pipefail

[[ -t 1 && -n "${QS_SESSION_KIND:-}" && -n "${QS_SANDBOX_NAME:-}" ]] || exit 0

printf '\033]0;%s | %s\007' "$QS_SANDBOX_NAME" "$QS_SESSION_KIND"
