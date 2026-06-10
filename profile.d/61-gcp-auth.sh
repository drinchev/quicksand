#!/bin/bash
# Point gcloud/gsutil at the short-lived access token minted on the host by
# `qs gcp-auth` / `qs gcp-token` and stored in the shared workspace at
# _quicksand/gcp-token. Downloadable service-account keys are blocked by the
# org policy iam.disableServiceAccountKeyCreation, so the sandbox runs on
# impersonated tokens instead.
#
# We set gcloud's auth/access_token_file property (persisted in the sandbox
# user's gcloud config), which is re-read on every gcloud call — so refreshing
# the token on the host with `qs gcp-token` propagates live, no re-entry needed.
#
# Profile scripts are executed, not sourced, so ~/.zshrc (which pins
# CLOUDSDK_PYTHON — see 48-install-gcloud.sh) is not loaded; we resolve the
# uv-managed Python 3.12 the same way here.
#
# Idempotent: no-op if gcloud is missing or no token has been provisioned.
set -Eeuo pipefail

# gcloud installs under ~/google-cloud-sdk/bin and isn't on PATH until ~/.zshrc
# runs, so resolve it explicitly (falling back to PATH just in case).
GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"
[[ -x "$GCLOUD" ]] || GCLOUD="$(command -v gcloud 2>/dev/null || true)"
[[ -n "$GCLOUD" && -x "$GCLOUD" ]] || exit 0

TOKEN_FILE="${SHARED_WORKSPACE:?}/_quicksand/gcp-token"
[[ -f "$TOKEN_FILE" ]] || exit 0

# Pin CLOUDSDK_PYTHON to the uv-managed 3.12; macOS's system 3.9 is too old.
UV="$HOME/.local/bin/uv"
[[ -x "$UV" ]] || UV="$(command -v uv 2>/dev/null || true)"
if [[ -n "$UV" ]]; then
    PY="$("$UV" python find 3.12 2>/dev/null || true)"
    [[ -n "$PY" && -x "$PY" ]] && export CLOUDSDK_PYTHON="$PY"
fi

# Tell gcloud to read its access token from the workspace file. Only write when
# it differs, to avoid a redundant gcloud invocation on every session entry.
CURRENT="$("$GCLOUD" config get-value auth/access_token_file 2>/dev/null || true)"
if [[ "$CURRENT" != "$TOKEN_FILE" ]]; then
    "$GCLOUD" config set auth/access_token_file "$TOKEN_FILE" >/dev/null 2>&1 \
        || echo "quicksand: could not set gcloud access_token_file — re-run 'qs gcp-auth ${QS_SANDBOX_NAME:-NAME} <project>'" >&2
fi

PROJECT_FILE="${SHARED_WORKSPACE}/_quicksand/gcp-project"
if [[ -f "$PROJECT_FILE" ]]; then
    PROJECT="$(< "$PROJECT_FILE")"
    [[ -n "$PROJECT" ]] \
        && "$GCLOUD" config set project "$PROJECT" >/dev/null 2>&1 || true
fi
