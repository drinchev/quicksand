#!/bin/bash
# Install the GitHub CLI (gh) into the sandbox so the repo-scoped fine-grained
# PAT set up by `qs gh-auth` can drive the GitHub API (PRs, comments, CI,
# branches). Installs the official release tarball into ~/.local/bin, which is
# already on the sandbox PATH. Git transport stays on the deploy key — gh is
# only for the API.
#
# Idempotent: no-op if gh is already present.
set -Eeuo pipefail

command -v gh >/dev/null 2>&1 && exit 0
[[ -x "$HOME/.local/bin/gh" ]] && exit 0

case "$(uname -m)" in
    arm64)  ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) echo "Unsupported arch for gh install: $(uname -m)" >&2; exit 1 ;;
esac

# Resolve the latest release tag from the redirect on /releases/latest, so we
# don't pin a version that goes stale.
VER="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/cli/cli/releases/latest \
        | sed -n 's#.*/tag/v##p')"
[[ -n "$VER" ]] || { echo "Could not resolve latest gh version" >&2; exit 1; }

echo "Installing gh $VER into sandbox..." >&2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

asset="gh_${VER}_macOS_${ARCH}"
curl -fsSL "https://github.com/cli/cli/releases/download/v${VER}/${asset}.zip" \
    -o "$tmp/gh.zip"
unzip -q "$tmp/gh.zip" -d "$tmp"

mkdir -p "$HOME/.local/bin"
cp "$tmp/$asset/bin/gh" "$HOME/.local/bin/gh"
chmod +x "$HOME/.local/bin/gh"
