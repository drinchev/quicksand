#!/bin/bash
# Give the sandbox a voice, and make Claude Code use it when it needs you.
#
#   1. Install the qs-say client onto the sandbox PATH (~/.local/bin). The
#      build stages it into _quicksand/bin/ from config/qs-say and loads
#      the host-side broker it talks to (see config/qs-say for why speech
#      has to happen on the host).
#   2. Seed Claude Code hooks in ~/.claude/settings.json that run it: on
#      Notification (permission_prompt, idle_prompt, agent_needs_input) and
#      on Stop, so the Mac says "<sandbox> is waiting for your input" when
#      Claude is waiting for you.
#
# The hooks are seeded ONCE — when settings.json doesn't mention qs-say yet
# — and never re-asserted, so editing or deleting either entry sticks.
# Existing settings, other hooks included, are merged into rather than
# replaced. A settings.json that isn't a JSON object is left alone with a
# warning rather than risk clobbering it. The client copy itself is
# refreshed whenever the staged one changes.
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
grep -qF qs-say "$SETTINGS" 2>/dev/null && exit 0

if ! command -v jq >/dev/null 2>&1; then
    echo "quicksand: jq not found — not adding the qs-say hooks to $SETTINGS" >&2
    exit 0
fi

mkdir -p "$(dirname "$SETTINGS")"
[[ -s "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    echo "quicksand: $SETTINGS is not a JSON object — not adding the qs-say hooks" >&2
    exit 0
fi

# The sandbox name is interpolated into a double-quoted shell string in the
# hook command; qs only allows [A-Za-z0-9_-] in names, so anything else
# (or no name) falls back to a neutral subject.
NAME="${QS_SANDBOX_NAME:-}"
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || NAME="Claude"

tmp="$(mktemp "$SETTINGS.XXXXXX")"
jq --arg cmd "$DEST" --arg name "$NAME" '
    .hooks //= {}
    | .hooks.Notification = ((.hooks.Notification // []) + [{
        matcher: "permission_prompt|idle_prompt|agent_needs_input",
        hooks: [{ type: "command", command: ($cmd + " \"" + $name + " needs your attention\"") }]
      }])
    | .hooks.Stop = ((.hooks.Stop // []) + [{
        hooks: [{ type: "command", command: ($cmd + " \"" + $name + " is waiting for your input\"") }]
      }])
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"
echo "quicksand: Claude Code will speak when it needs you (qs-say hooks in $SETTINGS — edit or delete them freely; try: qs-say hello)" >&2
