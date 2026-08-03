#!/bin/bash
# 00-lib.sh — shared helpers for profile.d hooks. SOURCED, never executed:
# this file is deliberately NOT executable, so the session loop (which runs
# every executable *.sh here) skips it, and hooks pull it in with
#
#   . "${SHARED_WORKSPACE:?}/_quicksand/profile.d/00-lib.sh"
#
# It is synced into the sandbox by the same rsync as the hooks themselves
# (and fingerprinted with them), so a hook can rely on it being present and
# current. Custom-overlay hooks (custom/profile.d/) may source it the same
# way. Keep this file dependency-free: helpers only, no side effects at
# source time.

# Map `uname -m` to the per-arch name a download URL wants: $1 for arm64,
# $2 for x86_64 (naming varies per vendor: amd64 vs x86_64 vs arm). Prints
# the name; fails on anything else, which aborts a `set -e` hook via the
# usual VAR="$(qs_arch ...)" assignment.
qs_arch() {
    case "$(uname -m)" in
        arm64)  printf '%s\n' "$1" ;;
        x86_64) printf '%s\n' "$2" ;;
        *) echo "Unsupported arch: $(uname -m)" >&2; return 1 ;;
    esac
}

# Locate pnpm wherever an installer generation put it: pnpm >= 10 installs
# the CLI at $PNPM_HOME/bin/pnpm; older standalone installers used
# $PNPM_HOME/pnpm directly. Prints the path; fails if pnpm is nowhere.
find_pnpm() {
    command -v pnpm 2>/dev/null && return 0
    local p
    for p in "$HOME/Library/pnpm/bin/pnpm" "$HOME/Library/pnpm/pnpm" \
             "$HOME/.local/share/pnpm/pnpm" "$HOME/.pnpm/pnpm"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# Register a qmd collection, tolerating re-runs after a partial failure: a
# collection that already exists is success, anything else is a real error
# (reported, retried next session). The caller sets $QMD to the qmd binary.
ensure_collection() {
    local out
    if out="$("$QMD" collection add "$@" 2>&1)"; then
        return 0
    fi
    grep -qi "exist" <<< "$out" && return 0
    echo "$out" >&2
    return 1
}
