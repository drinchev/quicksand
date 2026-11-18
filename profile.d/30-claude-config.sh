#!/bin/bash
# Seed Claude Code's configuration inside the sandbox:
#
#   1. ~/.claude.json         — onboarding flags so the first session isn't
#                               stuck on welcome prompts.
#   2. ~/.claude/quicksand.md — a description of the sandbox environment
#                               (filesystem boundary, gh access, credentials),
#                               copied from the config/quicksand.md asset the
#                               build syncs in; refreshed every run.
#   3. ~/.claude/CLAUDE.md     — the user-level memory file, which we touch only
#                               to ensure it imports quicksand.md (@import).
#   4. ~/.claude/settings.json — quicksand's defaults, from the
#                               config/claude-settings.json template the build
#                               syncs in. Each top-level key is added only
#                               while absent. One of them, cleanupPeriodDays,
#                               stops Claude Code deleting session transcripts
#                               after its default 30 days (old sessions then
#                               vanish from the resume picker).
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

# 4. settings.json — merge in the defaults from the claude-settings.json
# template the build syncs into _quicksand/. settings.json is not ours alone:
# Claude Code writes runtime state into it (/model, /theme, accepted prompts)
# and the user edits it, so the template is never copied over it. Instead each
# top-level key is added only while absent — whatever is already there wins,
# and a new default added to the template still reaches existing sandboxes.
# skipDangerousModePermissionPrompt is what keeps `qs claude` (which runs
# with --dangerously-skip-permissions) from stopping at the bypass-mode
# warning; it replaces the bypassPermissionsModeAccepted flag this script used
# to seed into ~/.claude.json, which Claude Code no longer keeps there.
# The merge is top-level only: hooks are seeded by their own scripts (see
# 31-claude-say.sh), which need per-sandbox values and seed-once semantics.
# A settings.json or template that isn't a JSON object is left alone with a
# warning rather than risk clobbering anything.
# QS_CLAUDE_SETTINGS overrides the settings path for tests.
SETTINGS="${QS_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
TEMPLATE="$SHARED_WORKSPACE/_quicksand/claude-settings.json"
# Not staged (the build predates the template) — nothing to merge.
[[ -f "$TEMPLATE" ]] || exit 0
if ! command -v jq >/dev/null 2>&1; then
    echo "quicksand: jq not found — not merging quicksand's defaults into $SETTINGS" >&2
    exit 0
fi
if ! jq -e 'type == "object"' "$TEMPLATE" >/dev/null 2>&1; then
    echo "quicksand: $TEMPLATE is not a JSON object — not merging it into $SETTINGS" >&2
    exit 0
fi
mkdir -p "$(dirname "$SETTINGS")"
[[ -s "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    echo "quicksand: $SETTINGS is not a JSON object — not merging quicksand's defaults into it" >&2
    exit 0
fi
# Rewrite only when the template has a key the settings lack.
if jq -e -s '(.[0] | keys) - (.[1] | keys) | length > 0' "$TEMPLATE" "$SETTINGS" >/dev/null 2>&1; then
    tmp="$(mktemp "$SETTINGS.XXXXXX")"
    # `+` is a shallow merge where the right side wins: existing settings
    # override the template, key by key.
    jq -s '.[0] + .[1]' "$TEMPLATE" "$SETTINGS" > "$tmp"
    # mktemp creates 0600; keep whatever mode the settings file already had.
    chmod "$(stat -f '%Lp' "$SETTINGS")" "$tmp"
    mv "$tmp" "$SETTINGS"
fi
