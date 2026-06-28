#!/bin/bash
# Install the 1Password CLI (op) into the sandbox so `op read`/`op run` can
# fetch app secrets from the per-sandbox vault set up by `qs op-auth`. Installs
# the standalone binary into ~/.local/bin, which is already on the sandbox
# PATH. Authentication is via the OP_SERVICE_ACCOUNT_TOKEN env var (see
# profile.d/62-op-auth.sh) — op needs no desktop app or interactive sign-in
# inside the sandbox.
#
# Idempotent: no-op if op is already present.
set -Eeuo pipefail

command -v op >/dev/null 2>&1 && exit 0
[[ -x "$HOME/.local/bin/op" ]] && exit 0

# 1Password ships per-arch macOS builds (no universal binary) and has no stable
# "latest" redirect like GitHub, so the version is pinned here — bump to upgrade.
VER="2.33.1"

case "$(uname -m)" in
    arm64)  ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) echo "Unsupported arch for op install: $(uname -m)" >&2; exit 1 ;;
esac

echo "Installing 1Password CLI $VER into sandbox..." >&2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v${VER}/op_darwin_${ARCH}_v${VER}.zip" \
    -o "$tmp/op.zip"
unzip -q "$tmp/op.zip" -d "$tmp"

mkdir -p "$HOME/.local/bin"
cp "$tmp/op" "$HOME/.local/bin/op"
chmod +x "$HOME/.local/bin/op"
