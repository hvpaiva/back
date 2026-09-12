#!/usr/bin/env bash
# What this working copy would change, and running it instead of Git (just diff, just local,
# just gitops). Argo CD enforces Git, and root enforces the Applications' own spec, so taking one
# over means pausing both: otherwise root undoes it within a minute.
#
#   scripts/local.sh diff apis     what applying platform/apis/ from here would change
#   scripts/local.sh apply apis    apply it, and stop Argo CD from putting Git back
#   scripts/local.sh gitops        put every Application back under Git
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

# The folder of this repository an Application delivers. Messages go to stderr: the caller reads stdout.
source_path() { # app
  local path
  if ! path=$(kubectl --namespace argocd get application "$1" --output jsonpath='{.spec.source.path}' 2>/dev/null); then
    { fail "no Application named $1"; hint "kubectl --namespace argocd get applications"; } >&2
    return 1
  fi
  if [[ -z $path || ! -d $path ]]; then
    { fail "$1 doesn't come from a folder of this repository"
      hint "it's installed from a Helm repository: change platform/apps/$1.yaml and push instead"; } >&2
    return 1
  fi
  echo "$path"
}

usage() { # command
  echo "usage: $(basename "$0") ${1:-diff|apply} <app>" >&2
  exit 2
}

case ${1:-} in
  diff)
    [[ -n ${2:-} ]] || usage diff
    path=$(source_path "$2")
    login
    section "What $path would change in the cluster"
    # A difference is the expected answer here, and the CLI exits non-zero for it.
    argocd app diff "$2" --local "$path" --exit-code=false
    ;;
  apply)
    [[ -n ${2:-} ]] || usage apply
    path=$(source_path "$2")
    section "Syncing $2 from $path"
    login
    argocd app set root --sync-policy manual >/dev/null
    argocd app set "$2" --sync-policy manual >/dev/null
    argocd app sync "$2" --local "$path"
    ok "$2 runs what's in $path, and stays OutOfSync against Git until you push it"
    hint "just gitops puts it back"
    ;;
  gitops)
    section "Back under Git"
    login
    argocd app set root --sync-policy automated --self-heal --auto-prune >/dev/null
    # Syncing root restores the Applications it manages, sync policy included, right away. It
    # refuses while an operation of its own is still running, and that's fine: self-heal gets there.
    argocd app sync root >/dev/null 2>&1 || true
    ok "root follows Git again, and the Applications it manages follow within a minute"
    hint "anything you applied from disk that Git doesn't have stays until you delete it"
    ;;
  *)
    echo "usage: $(basename "$0") diff <app> | apply <app> | gitops" >&2
    exit 2
    ;;
esac
