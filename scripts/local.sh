#!/usr/bin/env bash
# Hands one Application to this working copy, and hands everything back (just local <app>,
# just gitops). Argo CD enforces Git, and root enforces the Applications' own spec, so taking one
# over means pausing both: otherwise root undoes it within a minute.
#
#   scripts/local.sh apis      apply platform/apis from here, as it is on disk
#   scripts/local.sh gitops    put every Application back under Git
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# The CLI keeps its login in .argocd/, and only platform-admin may change an Application.
login() {
  argocd account get-user-info --output json 2>/dev/null | jq -e '.loggedIn' >/dev/null && return
  argocd login argocd.localhost:80 --skip-test-tls --name platform-admin --username platform-admin \
    --password "$(kubectl --namespace argocd get secret argocd-account-passwords \
      --output jsonpath='{.data.platform-admin}' | base64 --decode)" >/dev/null
}

case ${1:-} in
  "")
    echo "usage: $(basename "$0") <app>|gitops" >&2
    exit 2
    ;;
  gitops)
    section "Back under Git"
    login
    argocd app set root --sync-policy automated --self-heal --auto-prune >/dev/null
    # root re-applies the Applications it manages, which restores their sync policy too.
    argocd app sync root >/dev/null
    ok "root follows Git again, and the Applications it manages follow within a minute"
    hint "anything you applied from disk that Git doesn't have stays until you delete it"
    ;;
  *)
    app=$1
    if ! path=$(kubectl --namespace argocd get application "$app" --output jsonpath='{.spec.source.path}' 2>/dev/null); then
      fail "no Application named $app"
      hint "kubectl --namespace argocd get applications"
      exit 1
    fi
    if [[ -z $path || ! -d $path ]]; then
      fail "$app doesn't come from a folder of this repository"
      hint "it's installed from a Helm repository: change platform/apps/$app.yaml and push instead"
      exit 1
    fi
    section "Syncing $app from $path"
    login
    argocd app set root --sync-policy manual >/dev/null
    argocd app set "$app" --sync-policy manual >/dev/null
    argocd app sync "$app" --local "$path"
    ok "$app runs what's in $path, and stays OutOfSync against Git until you push it"
    hint "just gitops puts it back"
    ;;
esac
