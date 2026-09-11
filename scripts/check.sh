#!/usr/bin/env bash
# Smoke-tests the lab from the host (just check): every component answers, and hello runs
# in both stages and reaches its bucket.
set -euo pipefail
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

localstack() {
  curl -fsS http://localhost:4566/_localstack/health | jq -er '"\(.edition) \(.version), http://localhost:4566"'
}

argocd_server() {
  curl -fsS http://argocd.localhost/api/version |
    jq -er '"\(.Version | split("+")[0]), http://argocd.localhost (user admin, password: just argocd-password)"'
}

headlamp() {
  curl -fsS -o /dev/null http://headlamp.localhost/ && echo "http://headlamp.localhost (token: just headlamp-token)"
}

crossplane_packages() {
  kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io --output json | jq -er '.items
    | if length > 0 and all(any(.status.conditions[]?; .type == "Healthy" and .status == "True"))
      then "\(map(select(.kind == "Provider")) | length) providers and \(map(select(.kind == "Function")) | length) functions healthy (kubectl get providers,functions)"
      else error("some packages are not healthy: kubectl get providers,functions") end'
}

hello() { # stage url
  curl -fsS "$2/api/info" | jq -er --arg stage "$1" --arg url "$2" '
    if .bucket and (.bucket.reachable | not) then error("in \($stage), does not reach its bucket \(.bucket.name)")
    else "\(.version) in \($stage)\(if .bucket then ", bucket \(.bucket.name)" else "" end), \($url)" end'
}

section "Checking the lab"
report gateway gateway
report localstack localstack
report argocd argocd_server
report headlamp headlamp
report crossplane crossplane_packages
report hello hello staging http://hello.staging.localhost
report hello hello production http://hello.localhost
((problems == 0))
