#!/usr/bin/env bash
# Puts the lab back the way Git describes it, without rebuilding it (just reset): the requests
# nobody committed go, every Application follows Git again, and the cloud account comes back if an
# experiment stopped it. What it never touches is this working copy.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

request_kinds() {
  kubectl api-resources --api-group=back.lab --output name | paste -sd, -
}

# Argo CD annotates everything it delivers, so a request without that annotation was applied by hand.
applied_by_hand() { # kinds
  kubectl get "$1" --all-namespaces --output json | jq -r '
    .items[]
    | select((.metadata.annotations // {})["argocd.argoproj.io/tracking-id"] == null)
    | [.metadata.namespace, (.kind | ascii_downcase), .metadata.name] | @tsv'
}

still_composed() { # namespace/name...
  local request
  for request in "$@"; do
    kubectl --namespace "${request%%/*}" get managed \
      --selector "crossplane.io/composite=${request#*/}" --output name 2>/dev/null | sed 's/\..*\//\//'
  done
}

section "Undoing the experiments"

kinds=$(request_kinds)
mapfile -t requests < <(applied_by_hand "$kinds")

if ((${#requests[@]} == 0)); then
  ok "no requests to remove: everything the platform holds, Git asked for"
else
  removed=()
  while IFS=$'\t' read -r namespace kind name; do
    kubectl --namespace "$namespace" delete "$kind" "$name" --wait=false >/dev/null
    ok "$kind/$name in $namespace, and what it created"
    removed+=("$namespace/$name")
  done < <(printf '%s\n' "${requests[@]}")

  last=""
  for _ in $(seq 60); do
    mapfile -t remaining < <(
      applied_by_hand "$kinds" | cut -f2,3 | tr '\t' '/'
      still_composed "${removed[@]}"
    )
    ((${#remaining[@]} == 0)) && break
    pending=$(printf '%s\n' "${remaining[@]}" | paste -sd ' ' -)
    if [[ $pending != "$last" ]]; then
      waiting "$pending"
      last=$pending
    fi
    sleep 2
  done

  if ((${#remaining[@]} > 0)); then
    fail "$pending didn't go in two minutes"
    hint "Crossplane keeps what it composed until the provider confirms the delete, so an"
    hint "unreachable cloud account looks exactly like this: just check says whether it answers"
  else
    ok "every request applied by hand is gone, and so is what it created"
  fi
fi

replicas=$(kubectl --namespace cloud get deployment aws --output jsonpath='{.spec.replicas}' 2>/dev/null || true)
if [[ $replicas == 0 ]]; then
  scripts/base.sh cloud
elif [[ -z $replicas ]]; then
  warn "the cloud account isn't installed: just cloud"
fi

scripts/local.sh gitops

if [[ -n $(git status --porcelain) ]]; then
  section "Left alone"
  warn "this working copy still differs from Git"
  hint "what changed: git status"
fi

if ((problems > 0)); then exit 1; fi
