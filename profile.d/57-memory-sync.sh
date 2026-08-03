#!/bin/bash
# Sync and index the shared memory repo, if one is attached (`qs memory`).
# Reading: merged memories from other sandboxes arrive via a background
# `git pull` here and get indexed by 56's background `qmd update` (the two
# race harmlessly — anything missed lands next session). Writing crosses
# the sandbox boundary only through PRs; the conventions live in
# ~/.claude/quicksand.md. No-op for sandboxes without a memory repo.
set -Eeuo pipefail
# shellcheck source=/dev/null
. "${SHARED_WORKSPACE:?}/_quicksand/profile.d/00-lib.sh"

MEMORY_DIR="${SHARED_WORKSPACE:?}/memory"
[[ -d "$MEMORY_DIR/.git" ]] || exit 0

QMD="$HOME/.local/bin/qmd"

# One-time collection registration; versioned sentinel like 56-setup-qmd.sh.
SETUP_VERSION=1
STATE_DIR="$HOME/.local/state/quicksand"
SENTINEL="$STATE_DIR/memory-initialized"
if [[ -x "$QMD" && "$(cat "$SENTINEL" 2>/dev/null)" != "$SETUP_VERSION" ]]; then
    mkdir -p "$STATE_DIR"
    ensure_collection "$MEMORY_DIR" --name shared-memory
    "$QMD" context add qmd://shared-memory/ \
        "Cross-sandbox shared memory, merged via pull requests: durable knowledge written by agents in other sandboxes"
    echo "$SETUP_VERSION" > "$SENTINEL"
fi

# Rebase keeps local not-yet-merged memory commits on top of main and
# drops them automatically once their PR merges. Detached via subshell
# double-fork, not nohup: macOS nohup dies with "can't detach from
# console" in sessions without a TTY (e.g. piped ones).
( git -C "$MEMORY_DIR" pull --rebase --quiet > /dev/null 2>&1 & )
