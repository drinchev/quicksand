#!/bin/bash
# Register qmd collections and keep the index fresh. Together with
# 55-install-qmd.sh this gives every agent session searchable shared memory:
#
#   notes         — $SHARED_WORKSPACE/notes, the durable per-sandbox knowledge
#                   base agents write to (survives rebuilds; created at build)
#   claude-memory — Claude Code's auto-memory under ~/.claude/projects
#
# Collection registration is one-time data setup, so it's guarded by a state
# sentinel rather than a binary check. The index update runs every session,
# in the background — it's how notes written by one session become findable
# in the next. Embeddings (`qmd embed`) are deliberately NOT generated here:
# the first run downloads large GGUF models, and BM25 `qmd search` works
# without them; agents can run `qmd embed` themselves for semantic `qmd query`.
set -Eeuo pipefail

QMD="$HOME/.local/bin/qmd"
[[ -x "$QMD" ]] || exit 0

# Tolerate re-runs after a partial failure: a collection that already exists
# is success, anything else is a real error (reported, retried next session).
ensure_collection() {
    local out
    if out="$("$QMD" collection add "$@" 2>&1)"; then
        return 0
    fi
    grep -qi "exist" <<< "$out" && return 0
    echo "$out" >&2
    return 1
}

STATE_DIR="$HOME/.local/state/quicksand"
SENTINEL="$STATE_DIR/qmd-initialized"
if [[ ! -f "$SENTINEL" ]]; then
    mkdir -p "$STATE_DIR" "$HOME/.claude/projects"
    ensure_collection "${SHARED_WORKSPACE:?}/notes" --name notes
    # Only each project's memory/ dir; if this qmd version rejects the
    # cross-directory mask, fall back to indexing all markdown under
    # ~/.claude/projects (transcripts are jsonl, so the net is the same).
    ensure_collection "$HOME/.claude/projects" --name claude-memory \
            --mask "**/memory/**/*.md" \
        || ensure_collection "$HOME/.claude/projects" --name claude-memory
    touch "$SENTINEL"
fi

nohup "$QMD" update > /dev/null 2>&1 &
