#!/bin/bash
# Authenticate `gh` inside the sandbox using a repo-scoped fine-grained PAT
# created on the host by `qs gh-auth` (or `qs clone`) and dropped in the shared
# workspace at _quicksand/gh-token-<repo>.
#
# Profile scripts are executed, not sourced, so exporting GH_TOKEN here would
# not survive into the interactive shell. Instead we persist into gh's own
# credential store via `gh auth login --with-token`, which writes
# ~/.config/gh/hosts.yml and does NOT touch git (no `gh auth setup-git`) — so
# push/fetch keep using the deploy-key SSH remote and the token stays API-only.
#
# Idempotent: no-op if gh is missing, already authenticated, or no token file.
set -Eeuo pipefail

command -v gh >/dev/null 2>&1 || exit 0
gh auth status -h github.com >/dev/null 2>&1 && exit 0

# gh holds one token per host and these sandboxes are per-repository, so in
# practice there's exactly one token file. If several exist, use the first
# and say so rather than silently picking.
shopt -s nullglob
tokens=("${SHARED_WORKSPACE:?}"/_quicksand/gh-token-*)
(( ${#tokens[@]} )) || exit 0
(( ${#tokens[@]} > 1 )) \
    && echo "quicksand: multiple gh tokens found; using $(basename "${tokens[0]}")" >&2

gh auth login --with-token < "${tokens[0]}" >/dev/null 2>&1 \
    || echo "quicksand: gh token rejected (expired or revoked?) — re-run 'qs gh-auth'" >&2
