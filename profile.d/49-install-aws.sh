#!/bin/bash
# Install the AWS CLI v2 into the sandbox. AWS only ships a macOS .pkg (no
# tarball/zip like gh), and the sandbox user can't sudo.
#
# The documented per-user install (`installer -target CurrentUserHomeDirectory`)
# does NOT work here: a sandbox user entered via `sudo` has no Aqua/login
# session, so `installer` aborts with "Error trying to locate
# CurrentUserHomeDirectory domain" (exit 1) before writing anything — which is
# why the old version reinstalled on every entry. So we skip `installer`
# entirely and unpack the package payload by hand: the AWS CLI v2 is a
# self-contained directory, so extracting it under $HOME and symlinking
# aws/aws_completer into ~/.local/bin (already on the sandbox PATH) is enough.
#
# Idempotent: no-op if aws is already present.
set -Eeuo pipefail

command -v aws >/dev/null 2>&1 && exit 0
[[ -x "$HOME/.local/bin/aws" ]] && exit 0

echo "Installing AWS CLI v2 into sandbox..." >&2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Single universal (arm64 + x86_64) macOS package — no per-arch asset.
curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$tmp/AWSCLIV2.pkg"

# Expand the flat package and extract its payload (`--expand-full` unpacks the
# cpio Payload too) rather than running `installer`, which needs a GUI session.
pkgutil --expand-full "$tmp/AWSCLIV2.pkg" "$tmp/expanded"

# Locate the extracted, self-contained aws-cli/ directory (holds the binary).
payload="$(/usr/bin/find "$tmp/expanded" -type d -name aws-cli -path '*/Payload/*' -print -quit)"
[[ -n "$payload" && -x "$payload/aws" ]] || { echo "AWS CLI payload not found in package" >&2; exit 1; }

# Move it into place (replacing any partial install), then symlink onto PATH.
rm -rf "$HOME/aws-cli"
/bin/mv "$payload" "$HOME/aws-cli"
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/aws-cli/aws"           "$HOME/.local/bin/aws"
ln -sf "$HOME/aws-cli/aws_completer" "$HOME/.local/bin/aws_completer"
