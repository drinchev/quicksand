#!/bin/bash
# Seed Claude Code's configuration inside the sandbox:
#
#   1. ~/.claude.json         — onboarding flags so the first session isn't
#                               stuck on welcome prompts or the permission-mode
#                               warning.
#   2. ~/.claude/quicksand.md — a description of the sandbox environment
#                               (filesystem boundary, gh access, credentials),
#                               copied from the config/quicksand.md asset the
#                               build syncs in; refreshed every run.
#   3. ~/.claude/CLAUDE.md     — the user-level memory file, which we touch only
#                               to ensure it imports quicksand.md (@import).
#
# Idempotent. The onboarding file and CLAUDE.md are only created/extended, never
# clobbered, so manual edits (and Claude's own `#` memory writes) survive.
set -Eeuo pipefail

# 1. Onboarding flags — write only if missing so manual edits persist.
if [[ ! -f "$HOME/.claude.json" ]]; then
    cat > "$HOME/.claude.json" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "tipsHistory": { "new-user-warmup": 1 }
}
JSON
fi

mkdir -p "$HOME/.claude"

# 2. quicksand.md — copied from the config/quicksand.md asset the build syncs
# into _quicksand/. quicksand owns this file, so always refresh it (keeping the
# boundary/credential description in sync with the repo). Skip silently if the
# asset is missing rather than leaving a stale or empty file.
src="${SHARED_WORKSPACE:?}/_quicksand/quicksand.md"
if [[ -f "$src" ]]; then
    cp -f "$src" "$HOME/.claude/quicksand.md"

    # 3. CLAUDE.md — ensure it imports quicksand.md, without disturbing anything
    # else. A relative @import resolves against this file's own directory.
    claude_md="$HOME/.claude/CLAUDE.md"
    touch "$claude_md"
    grep -qxF '@quicksand.md' "$claude_md" || printf '@quicksand.md\n' >> "$claude_md"
fi
