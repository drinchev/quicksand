#!/bin/bash
# Seed Claude Code's onboarding flags so the first session doesn't get
# stuck on the welcome prompts and the permission-mode warning.
#
# Idempotent: only writes the file if it's missing, so manual edits the
# user makes inside the sandbox survive subsequent sessions.
set -Eeuo pipefail

if [[ ! -f "$HOME/.claude.json" ]]; then
    cat > "$HOME/.claude.json" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "tipsHistory": { "new-user-warmup": 1 }
}
JSON
fi
