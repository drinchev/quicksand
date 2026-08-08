#!/bin/bash
# Claude Code Stop hook: when a session has done substantial work but saved
# nothing durable, block the stop ONCE and ask the agent to check whether
# anything belongs in shared memory (notes/ or the memory repo). Every other
# case exits silently, so the session ends undisturbed.
set -Eeuo pipefail

INPUT="$(cat)"

# Claude is already continuing because a Stop hook blocked — never loop.
grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<< "$INPUT" && exit 0

json_field() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<< "$INPUT" | head -1
}
SESSION_ID="$(json_field session_id)"
TRANSCRIPT="$(json_field transcript_path)"
[[ -n "$SESSION_ID" && -f "$TRANSCRIPT" && -n "${SHARED_WORKSPACE:-}" ]] || exit 0

# Nudge at most once per session.
STATE_DIR="$HOME/.local/state/quicksand"
MARKER="$STATE_DIR/memory-nudge-$SESSION_ID"
[[ -f "$MARKER" ]] && exit 0

# Only sessions with substantial work. The transcript grows with every
# turn and tool call, so its size is a cheap proxy.
MIN_BYTES="${QS_MEMORY_NUDGE_MIN_BYTES:-200000}"
SIZE="$(/usr/bin/stat -f%z "$TRANSCRIPT" 2>/dev/null || echo 0)"
(( SIZE >= MIN_BYTES )) || exit 0

# Skip (permanently, via the marker) if something durable was already
# written this session: any markdown under notes/, the shared memory repo,
# or Claude's auto-memory newer than the transcript's creation time.
SESSION_START="$(/usr/bin/stat -f%B "$TRANSCRIPT" 2>/dev/null || echo 0)"
SINCE="$(/bin/date -r "$SESSION_START" '+%Y-%m-%dT%H:%M:%S')"
for dir in "$SHARED_WORKSPACE/notes" "$SHARED_WORKSPACE/memory" "$HOME/.claude/projects"; do
    [[ -d "$dir" ]] || continue
    if [[ -n "$(find "$dir" -type f -name '*.md' -newermt "$SINCE" -print -quit 2>/dev/null)" ]]; then
        mkdir -p "$STATE_DIR"
        touch "$MARKER"
        exit 0
    fi
done

mkdir -p "$STATE_DIR"
touch "$MARKER"
find "$STATE_DIR" -name 'memory-nudge-*' -type f -mtime +7 -delete 2>/dev/null || true

cat <<JSON
{"decision": "block", "reason": "End-of-session memory check (quicksand): this session did substantial work but nothing was saved to shared memory. If it produced durable decisions, findings, or handoffs, save them now — $SHARED_WORKSPACE/notes/ for this sandbox, or the shared memory repo (via PR) for cross-sandbox knowledge; conventions are in the Shared memory section of ~/.claude/quicksand.md. If nothing is genuinely worth keeping, just finish — do not invent notes to satisfy this check."}
JSON
