#!/usr/bin/env bash
# Gives Argo CD the GitHub App it reports deployments to GitHub with, from .env (just notifications).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

section "GitHub notifications"
if [[ -z ${GITHUB_APP_ID:-} ]]; then
  warn "no GitHub App in .env: Argo CD won't report deployments to GitHub (optional, see the README)"
  exit 0
fi
key_file=${GITHUB_APP_PRIVATE_KEY_FILE:?set GITHUB_APP_PRIVATE_KEY_FILE in .env}
key_file=${key_file/#\~/$HOME}
kubectl --namespace argocd create secret generic argocd-notifications-secret \
  --from-literal=github-appID="$GITHUB_APP_ID" \
  --from-literal=github-installationID="${GITHUB_APP_INSTALLATION_ID:?set GITHUB_APP_INSTALLATION_ID in .env}" \
  --from-file=github-privateKey="$key_file" \
  --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
ok "GitHub App stored: Argo CD reports the next deployments to GitHub"
