#!/bin/bash
# Per-session keychain bootstrap.
#
# A fresh macOS user has no default keychain, so tools that try to read or
# write credentials (claude code, git's osxkeychain helper, etc.) emit
# "A keychain could not be found". Create login.keychain-db with an empty
# password on first run, mark it default, restrict the search path to it
# alone, and unlock it every session.
#
# An empty password is fine because the sandbox is the security boundary;
# the keychain only needs to exist as a credential store. Pinning the
# search path to login.keychain-db (instead of leaving System.keychain on
# it) matches the sandbox-exec profile, which denies reads under
# /Library/Keychains.
set -Eeuo pipefail

mkdir -p "$HOME/Library/Keychains"
if [[ ! -f "$HOME/Library/Keychains/login.keychain-db" ]]; then
    security create-keychain    -p "" login.keychain-db
    security set-keychain-settings    login.keychain-db
    security default-keychain   -s    login.keychain-db
    security list-keychains     -s    login.keychain-db
fi
security unlock-keychain -p "" login.keychain-db
