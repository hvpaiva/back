#!/usr/bin/env bash
# Puts the lab back the way Git describes it, without rebuilding it (just reset): the requests nobody
# committed go, with what they left in the cloud account, every Application follows Git again, and
# the cloud account comes back if an experiment stopped it. It never touches this working copy.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# The endpoint is pinned: no AWS setting in this shell can send these deletes to a real account.
account=(env -u AWS_PROFILE AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
  aws --endpoint-url http://localhost:4566)

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

left_in_account() { # namespace kind name
  local uid
  uid=$(kubectl --namespace "$1" get "$2.back.lab" "$3" --output jsonpath='{.metadata.uid}')
  kubectl --namespace "$1" get managed --output json | jq -r --arg uid "$uid" '
    .items[]
    | select(any(.metadata.ownerReferences[]?; .uid == $uid))
    | select((.spec.managementPolicies // ["*"]) | any(.[]; . == "Delete" or . == "*") | not)
    | [.kind, .metadata.annotations["crossplane.io/external-name"]] | @tsv'
}

# `s3 rb --force` skips older versions, and S3 won't delete a bucket that still holds any.
empty_bucket() { # name
  local batch
  "${account[@]}" s3api list-object-versions --bucket "$1" --output json \
    --query '[Versions, DeleteMarkers][].{Key: Key, VersionId: VersionId}' |
    jq -c '. as $all | range(0; length; 1000) | {Objects: $all[.:. + 1000], Quiet: true}' |
    while read -r batch; do
      "${account[@]}" s3api delete-objects --bucket "$1" --delete "$batch" >/dev/null
    done
}

remove_from_account() { # kind name
  local label="${1,,} $2, which its request left in the cloud account"
  case $1 in
    Bucket)
      "${account[@]}" s3api head-bucket --bucket "$2" >/dev/null 2>&1 || return 0
      empty_bucket "$2"
      run "$label" "${account[@]}" s3api delete-bucket --bucket "$2"
      ;;
    Table)
      "${account[@]}" dynamodb describe-table --table-name "$2" >/dev/null 2>&1 || return 0
      run "$label" "${account[@]}" dynamodb delete-table --table-name "$2"
      ;;
    *) warn "$label: this script doesn't know how to remove a $1" ;;
  esac
}

section "Undoing the experiments"

replicas=$(kubectl --namespace cloud get deployment aws --output jsonpath='{.spec.replicas}' 2>/dev/null || true)
kinds=$(request_kinds)
mapfile -t requests < <(applied_by_hand "$kinds")
left=()

if ((${#requests[@]} == 0)); then
  ok "no requests to remove: everything the platform holds, Git asked for"
else
  removed=()
  while IFS=$'\t' read -r namespace kind name; do
    mapfile -t -O "${#left[@]}" left < <(left_in_account "$namespace" "$kind" "$name")
    kubectl --namespace "$namespace" delete "$kind.back.lab" "$name" --wait=false >/dev/null
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
    ok "every request applied by hand is gone, and so is what it composed in the cluster"
  fi
fi

if ((${#left[@]} > 0)); then
  if [[ $replicas == 0 ]]; then
    ok "what those requests left in the cloud account goes with it: the account is stopped, and comes back empty"
  else
    for entry in "${left[@]}"; do
      remove_from_account "${entry%%$'\t'*}" "${entry#*$'\t'}" || true
    done
  fi
fi

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
