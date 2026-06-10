#!/bin/bash
# Reset the iTerm2 tab color when the session ends, undoing the green set by
# profile.d/50-tab-color.sh so the tab returns to the theme default once
# you're back at the host shell.
#
# Runs from the EXIT trap installed by the qs launcher. Same guards as its
# profile.d counterpart: iTerm only (the escape is iTerm-proprietary) and
# only when stdout is a tty.
#
# Note: this fires on a normal session exit (`exit`, Ctrl-D, claude quitting).
# It does not run if the terminal window/tab is closed outright — but then
# the colored tab is gone anyway, so there is nothing to reset.
set -Eeuo pipefail

[[ "${TERM_PROGRAM:-}" == "iTerm.app" && -t 1 ]] || exit 0

printf '\033]6;1;bg;*;default\007'
