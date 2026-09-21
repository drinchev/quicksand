#!/bin/bash
# Give the sandbox a voice, and make Claude Code use it when it needs you.
#
#   1. Install the qs-say client onto the sandbox PATH (~/.local/bin). The
#      build stages it into _quicksand/bin/ from config/qs-say and loads
#      the host-side broker it talks to (see config/qs-say for why speech
#      has to happen on the host).
#   2. Seed Claude Code Notification hooks in ~/.claude/settings.json that
#      run it: idle_prompt (Claude finished ~60 s ago and you haven't typed)
#      says "<sandbox> is waiting for your input"; permission_prompt and
#      agent_needs_input say "<sandbox> needs your attention".
#
# Deliberately NOT a Stop hook: Stop fires after every response — including
# when Claude ends a turn to let background agents run and will resume by
# itself — and its payload carries nothing that tells "waiting for you"
# from "turn over, work continues". idle_prompt is Claude Code's own idle
# detector; the ~60 s delay is the price of no false alarms.
#
# The hooks are seeded ONCE — when settings.json doesn't mention qs-say yet
# — and never re-asserted, so editing or deleting an entry sticks. Existing
# settings, other hooks included, are merged into rather than replaced. A
# settings.json that isn't a JSON object is left alone with a warning
# rather than risk clobbering it. The client copy itself is refreshed
# whenever the staged one changes.
#
# Migration: the first release seeded a Stop hook plus a single combined
# Notification entry. Sandboxes carrying that exact shape are rewritten to
# the current one (only entries whose command runs qs-say are touched, so
# the user's own hooks survive).
set -Eeuo pipefail

SRC="${SHARED_WORKSPACE:?}/_quicksand/bin/qs-say"
DEST="$HOME/.local/bin/qs-say"
# Not staged (the build predates qs-say) — nothing to install or hook up.
[[ -f "$SRC" ]] || exit 0

if ! cmp -s "$SRC" "$DEST" 2>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    cp "$SRC" "$DEST"
    chmod 0755 "$DEST"
fi

# QS_CLAUDE_SETTINGS overrides the settings path for tests.
SETTINGS="${QS_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
    grep -qF qs-say "$SETTINGS" 2>/dev/null && exit 0
    echo "quicksand: jq not found — not adding the qs-say hooks to $SETTINGS" >&2
    exit 0
fi

# The sandbox name is interpolated into a double-quoted shell string in the
# hook command; qs only allows [A-Za-z0-9_-] in names, so anything else
# (or no name) falls back to a neutral subject.
NAME="${QS_SANDBOX_NAME:-}"
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || NAME="Claude"

if grep -qF qs-say "$SETTINGS" 2>/dev/null; then
    # Already seeded. Migrate the first-release shape if present, else done.
    LEGACY='["permission_prompt|idle_prompt|agent_needs_input"]'
    jq -e --argjson legacy "$LEGACY" '
        def runs_say: any(.hooks[]?; (.command // "") | test("qs-say"));
        (.hooks.Stop // [] | any(.[]; runs_say))
        or (.hooks.Notification // [] | any(.[]; runs_say and ((.matcher // "") | IN($legacy[]))))
    ' "$SETTINGS" >/dev/null 2>&1 || exit 0
    tmp="$(mktemp "$SETTINGS.XXXXXX")"
    jq --arg cmd "$DEST" --arg name "$NAME" --argjson legacy "$LEGACY" '
        def runs_say: any(.hooks[]?; (.command // "") | test("qs-say"));
        def legacy_notif: runs_say and ((.matcher // "") | IN($legacy[]));
        # Replace the combined Notification entry with the two current ones
        # only if it was there; a Stop-only leftover just gets dropped.
        ((.hooks.Notification // []) | any(.[]; legacy_notif)) as $had_legacy
        | .hooks.Stop |= (map(select(runs_say | not)))
        | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
        | .hooks.Notification |= (
            map(select(legacy_notif | not))
            + (if $had_legacy then
                [{ matcher: "idle_prompt",
                   hooks: [{ type: "command", command: ($cmd + " \"" + $name + " is waiting for your input\"") }] },
                 { matcher: "permission_prompt|agent_needs_input",
                   hooks: [{ type: "command", command: ($cmd + " \"" + $name + " needs your attention\"") }] }]
               else [] end))
    ' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "quicksand: qs-say hooks updated — no more announcement after every turn; Claude speaks only once it has been waiting on you (~60 s)" >&2
    exit 0
fi

mkdir -p "$(dirname "$SETTINGS")"
[[ -s "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    echo "quicksand: $SETTINGS is not a JSON object — not adding the qs-say hooks" >&2
    exit 0
fi

tmp="$(mktemp "$SETTINGS.XXXXXX")"
jq --arg cmd "$DEST" --arg name "$NAME" '
    .hooks //= {}
    | .hooks.Notification = ((.hooks.Notification // []) + [
        { matcher: "idle_prompt",
          hooks: [{ type: "command", command: ($cmd + " \"" + $name + " is waiting for your input\"") }] },
        { matcher: "permission_prompt|agent_needs_input",
          hooks: [{ type: "command", command: ($cmd + " \"" + $name + " needs your attention\"") }] }])
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"
echo "quicksand: Claude Code will speak once it has been waiting on you (qs-say hooks in $SETTINGS — edit or delete them freely; try: qs-say hello)" >&2
