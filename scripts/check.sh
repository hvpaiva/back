#!/usr/bin/env bash
# Smoke-tests the lab from the host (just check): every component answers, every identity
# authenticates, and hello runs in both stages and reaches its bucket.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# Prints what the command printed, as ok when it succeeded and as fail otherwise.
report() { # name command...
  local name=$1 details
  shift
  if details=$("$@" 2>&1); then
    ok "$(printf '%-11s %s' "$name" "$details")"
  else
    details=${details#jq: error (at *): }
    fail "$(printf '%-11s %s' "$name" "${details:-no answer}")"
  fi
}

gateway() {
  curl -fsS -o /dev/null http://traefik.localhost/dashboard/ && echo "http://traefik.localhost/dashboard/"
}

cloud() {
  curl -fsS http://localhost:4566/health | jq -er '"ministack \(.version) (\(.edition)), http://localhost:4566"'
}

argocd_server() {
  curl -fsS http://argocd.localhost/api/version |
    jq -er '"\(.Version | split("+")[0]), http://argocd.localhost (dev or platform-admin, password: just argocd-password <user>)"'
}

headlamp() {
  curl -fsS -o /dev/null http://headlamp.localhost/ && echo "http://headlamp.localhost (token: just headlamp-token)"
}

# Its page answers before it can reach the cluster, so ask the part that has to.
crossview() {
  local status granted group missing=()
  status=$(curl -fsS http://crossview.localhost/api/kubernetes/status | jq -r '.status')
  if [[ $status != ok ]]; then
    echo "its API answered ${status:-nothing}"
    return 1
  fi
  granted=$(kubectl get clusterrole crossview \
    --output jsonpath='{range .rules[*]}{range .apiGroups[*]}{@}{","}{end}{end}')
  # A group it can't read leaves its pages shorter, with no error there or anywhere else.
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

# Its page answers before it can reach the cloud account, and the lab gives it no way to write there.
stackport() {
  local status writes account
  read -r status writes < <(curl -fsS http://stackport.localhost/api/health |
    jq -r '[.status, (.writes_enabled | tostring)] | @tsv')
  if [[ $status != ok ]]; then
    echo "its API answered ${status:-nothing}"
    return 1
  fi
  if [[ $writes == true ]]; then
    echo "it can write to the cloud account: STACKPORT_ALLOW_WRITES in platform/stackport"
    return 1
  fi
  account=$(curl -fsS http://stackport.localhost/api/endpoints | jq -r '.endpoints[0].health')
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
  # Kyverno fills that webhook from the policies it finds; empty with policies in the cluster
  # means every write is passing straight through.
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

# Reloader only watches the namespaces it was given, and a service in any other one would keep
# running with the Secret it started with.
reloader() {
  local watched kinds namespace missing=()
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
  echo "watches $watched"
}

hello() { # stage url
  curl -fsS "$2/api/info" | jq -er --arg stage "$1" --arg url "$2" '
    if .bucket and (.bucket.reachable | not) then error("in \($stage), does not reach its bucket \(.bucket.name)")
    else "\(.version) in \($stage)\(if .bucket then ", bucket \(.bucket.name)" else "" end), \($url)" end'
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
if ((problems > 0)); then exit 1; fi
