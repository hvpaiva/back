#!/usr/bin/env bash
# Waits until every Argo CD Application is synced and healthy, for up to ten minutes (just wait).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

section "Waiting for Argo CD"
# root creates the other Applications in waves: require two healthy checks in a row.
healthy_checks=0
last=""
for _ in $(seq 120); do
  pending=$(kubectl --namespace argocd get applications --no-headers \
    --output custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null |
    awk '$2 != "Synced" || $3 != "Healthy" { print $1 }' | paste -sd ' ' -)
  count=$(kubectl --namespace argocd get applications --no-headers 2>/dev/null | wc -l)
  if [[ -z $pending && $count -gt 1 ]]; then
    healthy_checks=$((healthy_checks + 1))
    if ((healthy_checks == 2)); then
      ok "all $((count)) Applications are synced and healthy"
      exit 0
    fi
  else
    healthy_checks=0
    pending=${pending:-the Applications root creates}
    if [[ $pending != "$last" ]]; then
      waiting "$pending"
      last=$pending
    fi
  fi
  sleep 5
done
fail "gave up after 10 minutes, still waiting for $last"
hint "see http://argocd.localhost, or: kubectl -n argocd get applications"
exit 1
