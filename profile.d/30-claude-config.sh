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
#   4. ~/.claude/settings.json — cleanupPeriodDays, so Claude Code keeps session
#                               transcripts instead of deleting them after its
#                               default 30 days (old sessions then vanish from
#                               the resume picker).
#
# Idempotent. The onboarding file, CLAUDE.md and settings.json are only
# created/extended, never clobbered, so manual edits (and Claude's own `#`
# memory writes) survive.
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

# 4. settings.json — keep session transcripts. Claude Code sweeps transcripts
# older than cleanupPeriodDays (default 30) at startup; a sandbox is a
# long-lived workspace whose history is worth resuming, so seed ~10 years.
# Added only while the key is absent, so any value the user sets — a shorter
# one included — sticks. A settings.json that isn't a JSON object is left
# alone with a warning rather than risk clobbering it.
# QS_CLAUDE_SETTINGS overrides the settings path for tests.
SETTINGS="${QS_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
RETENTION_DAYS=3650
if ! command -v jq >/dev/null 2>&1; then
    grep -qF '"cleanupPeriodDays"' "$SETTINGS" 2>/dev/null \
        || echo "quicksand: jq not found — not setting cleanupPeriodDays in $SETTINGS (Claude Code will delete session transcripts after 30 days)" >&2
    exit 0
fi
mkdir -p "$(dirname "$SETTINGS")"
[[ -s "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    echo "quicksand: $SETTINGS is not a JSON object — not setting cleanupPeriodDays" >&2
    exit 0
fi
if ! jq -e 'has("cleanupPeriodDays")' "$SETTINGS" >/dev/null 2>&1; then
    tmp="$(mktemp "$SETTINGS.XXXXXX")"
    jq --argjson days "$RETENTION_DAYS" '.cleanupPeriodDays = $days' "$SETTINGS" > "$tmp"
    # mktemp creates 0600; keep whatever mode the settings file already had.
    chmod "$(stat -f '%Lp' "$SETTINGS")" "$tmp"
    mv "$tmp" "$SETTINGS"
fi
