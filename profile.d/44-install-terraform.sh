#!/bin/bash
# Install Terraform into the sandbox. HashiCorp ships a per-arch zip holding a
# single self-contained binary, so it drops straight into ~/.local/bin, which
# is already on the sandbox PATH.
#
# Idempotent: no-op if terraform is already present.
set -Eeuo pipefail
# shellcheck source=/dev/null
. "${SHARED_WORKSPACE:?}/_quicksand/profile.d/00-lib.sh"

command -v terraform >/dev/null 2>&1 && exit 0
[[ -x "$HOME/.local/bin/terraform" ]] && exit 0

ARCH="$(qs_arch arm64 amd64)"

# Resolve the latest release from HashiCorp's checkpoint API, so we don't pin
# a version that goes stale.
VER="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
        | sed -n 's/.*"current_version":"\([^"]*\)".*/\1/p')"
[[ -n "$VER" ]] || { echo "Could not resolve latest terraform version" >&2; exit 1; }

echo "Installing terraform $VER into sandbox..." >&2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://releases.hashicorp.com/terraform/${VER}/terraform_${VER}_darwin_${ARCH}.zip" \
    -o "$tmp/terraform.zip"
unzip -q "$tmp/terraform.zip" -d "$tmp"

mkdir -p "$HOME/.local/bin"
cp "$tmp/terraform" "$HOME/.local/bin/terraform"
chmod +x "$HOME/.local/bin/terraform"
