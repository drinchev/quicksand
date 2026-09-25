#!/bin/bash
# Per-session keychain bootstrap.
#
# A fresh macOS user has no default keychain, so tools that try to read or
# write credentials (claude code, git's osxkeychain helper, etc.) emit
# "A keychain could not be found". Create quicksand.keychain-db with an
# empty password on first run, mark it default, restrict the search path to
# it alone, and unlock it every session.
#
# The name matters. `security` special-cases any keychain whose filename
# stem ends in "login" (login.keychain-db, mylogin.keychain-db, ...): it
# ignores -p on those and defers to the user's account password. On macOS
# 26+ that broke the old login.keychain-db name here -- create-keychain
# still exited 0, but every later unlock-keychain -p "" failed with
# "The user name or passphrase you entered is not correct" (exit 51) once
# the keychain had locked on sleep. Any stem not ending in "login" is fine.
#
# An empty password is fine because the sandbox is the security boundary;
# the keychain only needs to exist as a credential store. Pinning the
# search path to quicksand.keychain-db (instead of leaving System.keychain
# on it) matches the sandbox-exec profile, which denies reads under
# /Library/Keychains.
set -Eeuo pipefail

readonly KEYCHAIN="quicksand.keychain-db"

mkdir -p "$HOME/Library/Keychains"
if [[ ! -f "$HOME/Library/Keychains/$KEYCHAIN" ]]; then
    security create-keychain    -p "" "$KEYCHAIN"
    security set-keychain-settings    "$KEYCHAIN"
fi
# Re-asserted every session: a pre-existing keychain from an older build may
# still have login.keychain-db as the default and on the search path.
security default-keychain   -s    "$KEYCHAIN"
security list-keychains     -s    "$KEYCHAIN"
security unlock-keychain    -p "" "$KEYCHAIN"
