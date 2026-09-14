#!/usr/bin/env bash
# What this working copy would change, and running it instead of Git (just diff, just local,
# just gitops). Argo CD enforces Git, and root enforces the Applications' own spec, so taking one
# over means pausing both: otherwise root undoes it within a minute.
#
#   scripts/local.sh diff apis     what applying platform/apis/ from here would change
#   scripts/local.sh apply apis    apply it, and stop Argo CD from putting Git back
#   scripts/local.sh gitops        put every Application back under Git
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# The CLI keeps its login in .argocd/, and only platform-admin may change an Application.
login() {
  local said
  argocd account get-user-info --output json 2>/dev/null | jq -e '.loggedIn' >/dev/null && return
  if ! said=$(argocd login argocd.localhost:80 --skip-test-tls --name platform-admin \
    --username platform-admin --password "$(kubectl --namespace argocd get secret \
      argocd-account-passwords --output jsonpath='{.data.platform-admin}' | base64 --decode)" 2>&1); then
    fail "platform-admin couldn't log in to Argo CD"
    details <<<"$said"
    exit 1
  fi
}

# Applications whose last sync came from a folder: Argo CD keeps comparing them against it, not Git.
pinned_to_disk() {
  kubectl --namespace argocd get applications --output json |
    jq -r '.items[] | select(((.status.operationState.operation.sync.manifests // []) | length) > 0) | .metadata.name'
}

# The folder of this repository an Application delivers, when Argo CD can sync it from disk at all:
# that takes one source pointing at a path here. Messages go to stderr: the caller reads stdout.
source_path() { # app
  local app=$1 application path
  if ! application=$(kubectl --namespace argocd get application "$app" --output json 2>/dev/null); then
    { fail "no Application named $app"; hint "kubectl --namespace argocd get applications"; } >&2
    return 1
  fi
  path=$(jq -r 'if ((.spec.sources // []) | length) > 0 then "" else .spec.source.path // "" end' <<<"$application")
  if [[ -n $path && -d $path ]]; then
    echo "$path"
    return 0
  fi
  if [[ $(jq -r '.spec.project' <<<"$application") == apps ]]; then
    { fail "$app is a service, and Argo CD syncs only single-source Applications from disk"
      hint "it reads charts/app and the service's own values from two repositories, and a local sync would render the chart without them"
      hint "change them and push; just render-service renders a service here first, for every stage"; } >&2
  else
    { fail "$app doesn't come from a folder of this repository"
      hint "it's installed from a Helm chart: change platform/apps/$app.yaml, or the values beside it, and push"; } >&2
  fi
  return 1
}

usage() { # command
  echo "usage: $(basename "$0") ${1:-diff|apply} <app>" >&2
  exit 2
}

case ${1:-} in
  diff)
    [[ -n ${2:-} ]] || usage diff
    path=$(source_path "$2") || exit 1
    login
    section "What $path would change in the cluster"
    # A difference is the expected answer here, and the CLI exits non-zero for it.
    KUBECTL_EXTERNAL_DIFF=${KUBECTL_EXTERNAL_DIFF:-diff -u --color} \
      argocd app diff "$2" --local "$path" --exit-code=false
    ;;
  apply)
    [[ -n ${2:-} ]] || usage apply
    path=$(source_path "$2") || exit 1
    section "Syncing $2 from $path"
    login
    argocd app set root --sync-policy manual >/dev/null
    argocd app set "$2" --sync-policy manual >/dev/null
    run "$2 runs what's in $path, and Argo CD compares it against that folder now, not against Git" \
      argocd app sync "$2" --local "$path" || exit 1
    if [[ $2 != root ]]; then
      hint "root is the one that shows OutOfSync: its copy of $2 still has Git's sync policy"
    fi
    hint "just gitops puts it back"
    ;;
  gitops)
    section "Back under Git"
    login
    argocd app set root --sync-policy automated --self-heal --auto-prune >/dev/null
    # Syncing root restores the Applications it manages, sync policy included, right away. It
    # refuses while an operation of its own is still running, and that's fine: self-heal gets there.
    spin "root follows Git again" argocd app sync root || true
    ok "root follows Git again, and the Applications it manages follow within a minute"
    while IFS= read -r app; do
      if spin "$app compares against Git again" argocd app sync "$app"; then
        ok "$app compares against Git again, not against a folder"
      else
        warn "$app still compares against a folder on disk: argocd app sync $app"
      fi
    done < <(pinned_to_disk)
    hint "anything you applied from disk that Git doesn't have stays until you delete it"
    ;;
  *)
    echo "usage: $(basename "$0") diff <app> | apply <app> | gitops" >&2
    exit 2
    ;;
esac
