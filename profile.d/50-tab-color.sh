#!/bin/bash
# Tint the iTerm2 tab green on every session entry, so a sandbox tab is
# visually distinct from a host-shell tab.
#
# Uses iTerm2's proprietary OSC 6 sequence, which sets the tab background
# one RGB channel at a time:
#   ESC ] 6 ; 1 ; bg ; <red|green|blue> ; brightness ; <0-255> BEL
# `bg;*;default` resets to the theme default.
#
# Guarded on:
#   - TERM_PROGRAM == iTerm.app (forwarded by the qs launcher) — the escape
#     is iTerm-only and would print garbage in other terminals.
#   - stdout being a tty — no point emitting control codes into a pipe.
#
# Not idempotent in the file-writing sense (it's a runtime escape, not a
# config file); it simply re-asserts the color each entry, which is cheap.
set -Eeuo pipefail

[[ "${TERM_PROGRAM:-}" == "iTerm.app" && -t 1 ]] || exit 0

# #339900 — the sandbox green.
printf '\033]6;1;bg;red;brightness;51\007'
printf '\033]6;1;bg;green;brightness;153\007'
printf '\033]6;1;bg;blue;brightness;0\007'
