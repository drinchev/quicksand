#!/bin/bash
# Install the AWS CLI v2 into the sandbox. AWS only ships a macOS .pkg (no
# tarball/zip like gh), and the sandbox user can't sudo, so we install per-user
# with `installer -target CurrentUserHomeDirectory` plus a choices XML that
# relocates the payload under $HOME. That drops the CLI at ~/aws-cli/aws; we
# symlink it into ~/.local/bin, which is already on the sandbox PATH.
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

# Relocate the payload under $HOME so the install needs no sudo.
cat > "$tmp/choices.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <array>
    <dict>
      <key>choiceAttribute</key>
      <string>customLocation</string>
      <key>attributeSetting</key>
      <string>$HOME</string>
      <key>choiceIdentifier</key>
      <string>default</string>
    </dict>
  </array>
</plist>
EOF

installer -pkg "$tmp/AWSCLIV2.pkg" \
    -target CurrentUserHomeDirectory \
    -applyChoiceChangesXML "$tmp/choices.xml" >/dev/null

mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/aws-cli/aws" "$HOME/.local/bin/aws"
ln -sf "$HOME/aws-cli/aws_completer" "$HOME/.local/bin/aws_completer"
