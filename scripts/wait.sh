#!/usr/bin/env bash
# Waits until every Argo CD Application is synced and healthy, for up to ten minutes (just wait).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

section "Waiting for Argo CD"
# root creates the other Applications in waves: require two healthy checks in a row.
healthy_checks=0
last=""
last_failed=""
for _ in $(seq 120); do
  apps=$(kubectl --namespace argocd get applications --output json 2>/dev/null | jq -r '.items[] |
    [.metadata.name, (.status.sync.status // "-"), (.status.health.status // "-"),
     ((.status.operationState.syncResult.resources // []) | map(select(.status == "SyncFailed")) | length)] | @tsv')
  pending=$(awk -F'\t' '$2 != "Synced" || $3 != "Healthy" { print $1 }' <<<"$apps" | paste -sd ' ' -)
  count=$(awk 'NF { n++ } END { print n + 0 }' <<<"$apps")
  failed=$(awk -F'\t' '$4 > 0 { print $1 }' <<<"$apps" | paste -sd ' ' -)
  if [[ -n $failed && $failed != "$last_failed" ]]; then
    warn "$failed: something in it wouldn't apply, and Argo CD keeps trying"
    hint "what it says: kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}'"
  fi
  last_failed=$failed
  if [[ -z $pending && $count -gt 1 ]]; then
    healthy_checks=$((healthy_checks + 1))
    if ((healthy_checks == 2)); then
      ok "all $((count)) Applications are synced and healthy"
      exit 0
    fi
  else
    healthy_checks=0
    if [[ $pending != "$last" ]]; then
      if [[ -z $pending ]]; then
        waiting "the Applications root creates"
      elif ((count > 1)); then
        waiting "$((count - $(wc -w <<<"$pending"))) of $count Applications ready, waiting for $pending"
      else
        waiting "$pending"
      fi
      last=$pending
    fi
  fi
  sleep 5
done
fail "gave up after 10 minutes, still waiting for $last"
hint "see http://argocd.localhost, or: kubectl -n argocd get applications"
exit 1
