#!/usr/bin/env bash
# Hands the lab's GitHub App to the two things that use it: Argo CD, which reports deployments, and Kargo,
# which pushes what it promotes. Reads .env, and never prints the key (just github-app).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

section "GitHub App"
if [[ -z ${GITHUB_APP_ID:-} ]]; then
  warn "no GitHub App in .env: Argo CD won't report deployments, and Kargo has nothing to push with (see the README)"
  exit 0
fi
key_file=${GITHUB_APP_PRIVATE_KEY_FILE:?set GITHUB_APP_PRIVATE_KEY_FILE in .env}
key_file=${key_file/#\~/$HOME}
installation=${GITHUB_APP_INSTALLATION_ID:?set GITHUB_APP_INSTALLATION_ID in .env}

kubectl --namespace argocd create secret generic argocd-notifications-secret \
  --from-literal=github-appID="$GITHUB_APP_ID" \
  --from-literal=github-installationID="$installation" \
  --from-file=github-privateKey="$key_file" \
  --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
ok "Argo CD reports the next deployments to GitHub"

if [[ -z ${GITHUB_APP_CLIENT_ID:-} ]]; then
  warn "no GITHUB_APP_CLIENT_ID in .env: Kargo can't push what it promotes (the App's own settings page has it)"
  exit 0
fi
if ! kubectl get namespace apps >/dev/null 2>&1; then
  warn "Kargo hasn't made the apps namespace yet: run this again once it has"
  exit 0
fi
# Whichever account holds this copy of the lab, which is the one the services' repositories are under.
owner=$(git remote get-url origin | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#; s#\.git$##')
kubectl --namespace apps create secret generic github \
  --from-literal=repoURL="https://github.com/$owner/.*" \
  --from-literal=repoURLIsRegex=true \
  --from-literal=githubAppClientID="$GITHUB_APP_CLIENT_ID" \
  --from-literal=githubAppInstallationID="$installation" \
  --from-file=githubAppPrivateKey="$key_file" \
  --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
kubectl --namespace apps label secret github kargo.akuity.io/cred-type=git --overwrite >/dev/null
ok "Kargo pushes to $owner's repositories as the App"
