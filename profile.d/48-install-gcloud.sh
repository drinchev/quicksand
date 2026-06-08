#!/bin/bash
# Install Google Cloud SDK in the sandbox (provides gcloud, gsutil, bq).
#
# No upstream curl-pipe-to-sh installer; we fetch the platform tarball,
# extract into $HOME, and run its install.sh non-interactively. macOS's
# system Python is too old (3.9), so we use the Python 3.12 installed
# by 47-install-python.sh and pin CLOUDSDK_PYTHON in ~/.zshrc.
set -Eeuo pipefail

UV="$HOME/.local/bin/uv"
[[ -x "$UV" ]] || UV="$(command -v uv 2>/dev/null || true)"
[[ -n "$UV" ]] || { echo "uv not found; run 47-install-python.sh first" >&2; exit 1; }

PYTHON312="$("$UV" python find 3.12 2>/dev/null || true)"
[[ -n "$PYTHON312" && -x "$PYTHON312" ]] \
    || { echo "Python 3.12 not found; run 47-install-python.sh first" >&2; exit 1; }

if command -v gcloud >/dev/null 2>&1; then
    exit 0
fi
if [[ -x "$HOME/google-cloud-sdk/bin/gcloud" ]]; then
    # Verify the existing install actually runs (using the right Python).
    # Catches partial installs that left a binary behind with broken deps.
    if CLOUDSDK_PYTHON="$PYTHON312" \
        "$HOME/google-cloud-sdk/bin/gcloud" --version >/dev/null 2>&1; then
        exit 0
    fi
    echo "Found broken gcloud install at $HOME/google-cloud-sdk; reinstalling..." >&2
    rm -rf "$HOME/google-cloud-sdk"
fi

case "$(uname -m)" in
    arm64)  PKG="google-cloud-cli-darwin-arm.tar.gz" ;;
    x86_64) PKG="google-cloud-cli-darwin-x86_64.tar.gz" ;;
    *)      echo "Unsupported arch for gcloud install: $(uname -m)" >&2; exit 1 ;;
esac

echo "Installing Google Cloud SDK into sandbox (Python: $PYTHON312)..." >&2
cd "$HOME"
curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$PKG" | tar -xz

export CLOUDSDK_PYTHON="$PYTHON312"
"$HOME/google-cloud-sdk/install.sh" \
    --quiet \
    --usage-reporting=false \
    --command-completion=true \
    --path-update=true \
    --rc-path="$HOME/.zshrc" \
    --install-python=false

# Persist CLOUDSDK_PYTHON in ~/.zshrc so future shells (and gcloud calls)
# use the uv-managed Python rather than picking up macOS's system 3.9.
if ! grep -q '^export CLOUDSDK_PYTHON=' "$HOME/.zshrc" 2>/dev/null; then
    {
        echo ""
        echo "# Pin Google Cloud SDK to uv-managed Python (system 3.9 is too old)"
        echo "export CLOUDSDK_PYTHON='$PYTHON312'"
    } >> "$HOME/.zshrc"
fi
