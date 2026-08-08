#!/bin/bash
# Point this account's default browser at the host's, so URLs opened inside
# the sandbox (Claude Code's /login, gh's web flows) launch in the browser
# you actually use. A fresh user has no LaunchServices handler prefs, so URL
# opens resolve to the system fallback — Safari — before the app launches in
# the console (host) GUI session, the only one there is.
#
# QS_HOST_BROWSER is the host default browser's bundle id, detected from the
# host's LaunchServices prefs by the qs launcher and forwarded on every
# session. It is unset when the host default is Safari (a fallback, never
# recorded as a choice) or undetectable — then this no-ops and the sandbox's
# own Safari fallback is already right.
#
# Writing the prefs directly (rather than the LSSetDefaultHandler API) needs
# no GUI consent dialog — this account can't show one. Overwriting the whole
# LSHandlers array is safe here: a sandbox account never accumulates other
# handler choices. lsd serves handler lookups from a cache, so it's restarted
# after a write (`lsregister -kill` used to do this but was removed from
# macOS); killall only reaches this account's own lsd, and launchd respawns
# it on demand.
#
# Idempotent: exits early when the prefs already name this bundle id.
set -Eeuo pipefail

BUNDLE_ID="${QS_HOST_BROWSER:-}"
[[ -n "$BUNDLE_ID" ]] || exit 0
# Belt and braces: the id is interpolated into a quoted plist string below.
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

# QS_LS_PREFS overrides the prefs path for tests (like QS_DOCKER_SOCK in
# qs-docker): defaults(1) treats a path under $HOME/Library/Preferences as a
# cfprefsd *domain*, so tests must point at a literal file elsewhere rather
# than fake HOME — that would write into the invoking user's real prefs.
PLIST="${QS_LS_PREFS:-$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure}"
defaults read "$PLIST" LSHandlers 2>/dev/null | grep -qF "\"$BUNDLE_ID\"" && exit 0

mkdir -p "$(dirname "$PLIST")"
defaults write "$PLIST" LSHandlers -array \
    "{ LSHandlerURLScheme = http;  LSHandlerRoleAll = \"$BUNDLE_ID\"; }" \
    "{ LSHandlerURLScheme = https; LSHandlerRoleAll = \"$BUNDLE_ID\"; }"

killall lsd 2>/dev/null || true
