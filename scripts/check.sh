#!/usr/bin/env bash
# Smoke-tests the lab from the host (just check).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

report() { # name command...
  local name=$1 said
  shift
  if spin "$name" "$@"; then
    ok "$(printf '%-11s %s' "$name" "$spun")"
  else
    said=${spun#jq: error (at *): }
    fail "$(printf '%-11s %s' "$name" "${said:-no answer}")"
  fi
}

web() { curl -fsS --max-time 30 "$@"; }

gateway() {
  web -o /dev/null http://traefik.localhost/dashboard/ && echo "http://traefik.localhost/dashboard/"
}

cloud() {
  web http://localhost:4566/health | jq -er '"ministack \(.version) (\(.edition)), http://localhost:4566"'
}

argocd_server() {
  web http://argocd.localhost/api/version |
    jq -er '"\(.Version | split("+")[0]), http://argocd.localhost (dev or platform-admin, password: just argocd-password <user>)"'
}

headlamp() {
  web -o /dev/null http://headlamp.localhost/ && echo "http://headlamp.localhost (token: just headlamp-token)"
}

# Its page answers before it can reach the cluster, so ask the part that has to.
crossview() {
  local status granted group missing=()
  status=$(web http://crossview.localhost/api/kubernetes/status | jq -r '.status')
  if [[ $status != ok ]]; then
    echo "its API answered ${status:-nothing}"
    return 1
  fi
  granted=$(kubectl get clusterrole crossview \
    --output jsonpath='{range .rules[*]}{range .apiGroups[*]}{@}{","}{end}{end}')
  while IFS= read -r group; do
    [[ -n $group && ",$granted" != *",$group,"* ]] && missing+=("$group")
  done < <({
    kubectl api-resources --categories=crossplane --output name | sed 's/^[^.]*\.//'
    kubectl get compositeresourcedefinitions \
      --output jsonpath='{range .items[*]}{.spec.group}{"\n"}{end}'
  } | sort -u)
  if ((${#missing[@]} > 0)); then
    echo "doesn't read ${missing[*]}, which the cluster serves: add them in platform/crossview/rbac.yaml"
    return 1
  fi
  echo "http://crossview.localhost"
}

# Its page answers before it can reach the cloud account, so ask its API.
stackport() {
  local status writes account
  read -r status writes < <(web http://stackport.localhost/api/health |
    jq -r '[.status, (.writes_enabled | tostring)] | @tsv')
  if [[ $status != ok ]]; then
    echo "its API answered ${status:-nothing}"
    return 1
  fi
  if [[ $writes == true ]]; then
    echo "it can write to the cloud account: STACKPORT_ALLOW_WRITES in platform/stackport"
    return 1
  fi
  if ! account=$(web http://stackport.localhost/api/endpoints 2>/dev/null | jq -r '.endpoints[0].health'); then
    echo "it stopped answering about the cloud account, which is what it does while that account is unreachable"
    return 1
  fi
  if [[ $account != healthy ]]; then
    echo "it calls the cloud account $account, and its own page won't say so"
    return 1
  fi
  echo "http://stackport.localhost (read-only)"
}

# It answers admission requests before any policy selects anything, so ask what it intercepts.
kyverno() {
  local version kinds policies webhooks
  version=$(kubectl --namespace kyverno get deployment kyverno-admission-controller \
    --output jsonpath='{.spec.template.spec.containers[0].image}')
  kinds=$({ kubectl api-resources --api-group=policies.kyverno.io --output name
            kubectl api-resources --api-group=kyverno.io --output name; } |
    grep -E '^(namespaced)?(validating|mutating|generating|imagevalidating)policies\.|^(cluster)?policies\.kyverno\.io$' |
    paste -sd, -)
  policies=$(kubectl get "$kinds" --all-namespaces --output name 2>/dev/null | wc -l)
  webhooks=$(kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    --output json | jq '.webhooks | length')
  if ((policies > 0 && webhooks == 0)); then
    echo "$policies policies, and nothing reaches its webhook: kubectl --namespace kyverno logs deployment/kyverno-admission-controller"
    return 1
  fi
  echo "${version##*:}, $policies policies in force"
}

crossplane_packages() {
  kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io --output json | jq -er '.items
    | if length > 0 and all(any(.status.conditions[]?; .type == "Healthy" and .status == "True"))
      then "\(map(select(.kind == "Provider")) | length) providers and \(map(select(.kind == "Function")) | length) functions healthy (kubectl get providers,functions)"
      else error("some packages are not healthy: kubectl get providers,functions") end'
}

reloader() {
  local watched kinds namespace namespaces missing=() unreadable=()
  watched=$(kubectl --namespace reloader get deployment reloader-reloader \
    --output jsonpath='{.spec.template.spec.containers[0].args}' |
    jq -r '.[] | select(startswith("--namespaces=")) | ltrimstr("--namespaces=")')
  if [[ -z $watched ]]; then
    echo "watches every namespace in the cluster, Argo CD's and the platform's included"
    return 0
  fi
  kinds=$(kubectl api-resources --api-group=back.lab --output name | paste -sd, -)
  if [[ -n $kinds ]]; then
    while IFS= read -r namespace; do
      [[ -n $namespace && ",$watched," != *",$namespace,"* ]] && missing+=("$namespace")
    done < <(kubectl get "$kinds" --all-namespaces \
      --output jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)
  fi
  if ((${#missing[@]} > 0)); then
    echo "doesn't watch ${missing[*]}, where requests live: add them in platform/apps/reloader.yaml"
    return 1
  fi
  IFS=, read -ra namespaces <<<"$watched"
  for namespace in "${namespaces[@]}"; do
    if ! kubectl auth can-i list secrets --namespace "$namespace" \
      --as system:serviceaccount:reloader:reloader-reloader >/dev/null 2>&1; then
      unreadable+=("$namespace")
    fi
  done
  if ((${#unreadable[@]} > 0)); then
    echo "can't read Secrets in ${unreadable[*]}: nothing binds the reloader ClusterRole there"
    return 1
  fi
  echo "watches $watched"
}

hello() { # stage url
  web "$2/api/info" | jq -er --arg stage "$1" --arg url "$2" '
    if .bucket and (.bucket.reachable | not) then error("in \($stage), does not reach its bucket \(.bucket.name)")
    elif .database and (.database.reachable | not) then error("in \($stage), does not reach its database \(.database.host)")
    else "\(.version) in \($stage)\(if .bucket then ", bucket \(.bucket.name)" else "" end)\(if .database then ", database \(.database.host)" else "" end), \($url)" end'
}

# Backups run daily: none in 25 hours means one was missed, unless the database is minutes old.
backups() {
  kubectl get databases.back.lab --all-namespaces --output json | jq -er '
    def age(time): now - (time | fromdateiso8601);
    [.items[] | {
      name: "\(.metadata.namespace)/\(.metadata.name)",
      young: (age(.metadata.creationTimestamp) < 600),
      archiving: .status.backups.archiving,
      last: .status.backups.lastBackup
    }] as $all
    | ($all | map(select(.archiving == "failing") | .name)) as $failing
    | ($all | map(select(.last == null and (.young | not)) | .name)) as $never
    | ($all | map(select(.last != null and age(.last) > 90000) | .name)) as $missed
    | if ($all | length) == 0 then "no databases to back up"
      elif ($failing | length) > 0 then error("archiving is failing for \($failing | join(", ")): kubectl describe databases.back.lab")
      elif ($never | length) > 0 then error("never backed up: \($never | join(", "))")
      elif ($missed | length) > 0 then error("no backup in the last 25 hours for \($missed | join(", "))")
      else $all | map(if .last then "\(.name) \(age(.last) / 60 | floor)m ago" else "\(.name) waiting for its first" end) | join(", ") end'
}

section "Checking the lab"
report gateway gateway
report cloud cloud
report argocd argocd_server
report headlamp headlamp
report crossview crossview
report stackport stackport
report crossplane crossplane_packages
report reloader reloader
report kyverno kyverno
scripts/identities.sh check || problems=$((problems + 1))
report hello hello staging http://hello.staging.localhost
report hello hello production http://hello.localhost
report backups backups
if ((problems > 0)); then exit 1; fi
