#!/usr/bin/env bash
# Undoes the experiments without rebuilding the lab, and never touches this working copy (just reset).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# The endpoint is pinned: no AWS setting in this shell can send these deletes to a real account.
account=(env -u AWS_PROFILE AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
  aws --endpoint-url http://localhost:4566)

request_kinds() {
  kubectl api-resources --api-group=back.lab --output name | paste -sd, -
}

# Argo CD annotates everything it delivers, and what a request composed goes with that request: the rest was applied by hand.
applied_by_hand() { # kinds
  kubectl get "$1" --all-namespaces --output json | jq -r '
    .items[]
    | select((.metadata.annotations // {})["argocd.argoproj.io/tracking-id"] == null)
    | select(any(.metadata.ownerReferences[]?; .controller == true) | not)
    | [.metadata.namespace, (.kind | ascii_downcase), .metadata.name] | @tsv'
}

still_there() { # namespace/kind/name...
  local request namespace kind name
  for request in "$@"; do
    IFS=/ read -r namespace kind name <<<"$request"
    kubectl --namespace "$namespace" get "$kind.back.lab" "$name" --output name 2>/dev/null | sed 's/\..*\//\//'
  done
}

still_composed() { # namespace/kind/name...
  local request
  for request in "$@"; do
    kubectl --namespace "${request%%/*}" get managed \
      --selector "crossplane.io/composite=${request##*/}" --output name 2>/dev/null | sed 's/\..*\//\//'
  done
}

left_in_account() { # namespace kind name
  local owners new
  owners=$(kubectl --namespace "$1" get "$2.back.lab" "$3" --output jsonpath='{.metadata.uid}')
  # A request can compose other requests, and what those leave in the account is still this one's.
  while new=$(kubectl --namespace "$1" get "$kinds" --output json | jq -r --arg owners "$owners" '
      ($owners | split(" ")) as $known
      | .items[]
      | select(any(.metadata.ownerReferences[]?; .uid as $uid | $known | index($uid)))
      | .metadata.uid | select(. as $uid | $known | index($uid) | not)') && [[ -n $new ]]; do
    owners="$owners $(paste -sd' ' - <<<"$new")"
  done
  kubectl --namespace "$1" get managed --output json | jq -r --arg owners "$owners" '
    ($owners | split(" ")) as $known
    | .items[]
    | select(any(.metadata.ownerReferences[]?; .uid as $uid | $known | index($uid)))
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

# A Usage refuses deleting what it protects, so the ones applied by hand go before the requests.
mapfile -t usages < <(applied_by_hand usages.protection.crossplane.io)
for usage in "${usages[@]}"; do
  IFS=$'\t' read -r namespace _ name <<<"$usage"
  if errors=$(kubectl --namespace "$namespace" delete usages.protection.crossplane.io "$name" --timeout=60s 2>&1 >/dev/null); then
    ok "usage/$name in $namespace"
  else
    fail "usage/$name in $namespace stays"
    hint "$errors"
  fi
done

if ((${#requests[@]} == 0)); then
  ok "no requests to remove: everything the platform holds, Git asked for"
else
  removed=()
  while IFS=$'\t' read -r namespace kind name; do
    mapfile -t leaves < <(left_in_account "$namespace" "$kind" "$name")
    if ! errors=$(kubectl --namespace "$namespace" delete "$kind.back.lab" "$name" --wait=false 2>&1 >/dev/null); then
      fail "$kind/$name in $namespace stays"
      hint "${errors##*denied the request: }"
      continue
    fi
    left+=("${leaves[@]}")
    ok "$kind/$name in $namespace, and what it created"
    removed+=("$namespace/$kind/$name")
  done < <(printf '%s\n' "${requests[@]}")

  last=""
  for _ in $(seq 60); do
    mapfile -t remaining < <(
      still_there "${removed[@]}"
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
  elif ((${#removed[@]} == ${#requests[@]})); then
    ok "every request applied by hand is gone, and so is what it composed in the cluster"
  elif ((${#removed[@]} > 0)); then
    ok "the other requests are gone, and so is what they composed in the cluster"
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
