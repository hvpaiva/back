#!/usr/bin/env bash
# Renders a service through the platform's chart, for every stage, the way the delivery workflow
# validates a pull request (just render-service [path]). The manifests go to stdout and the verdict
# to stderr, and with the lab running each stage is also put to the API server as a dry run.
#
#   scripts/render-service.sh                            ../back-hello/charts/hello
#   scripts/render-service.sh ../back-other/charts/api   another service, from its chart folder
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

chart=${1:-../back-hello/charts/hello}
if [[ ! -f $chart/values.yaml ]]; then
  echo "usage: $(basename "$0") <path to a service's chart folder>" >&2
  echo "no values.yaml in $chart" >&2
  exit 2
fi
# The release name only names the Helm release: the objects are named after application.name.
service=$(basename "$chart")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rendered=()

for stage in staging production; do
  values=(--values "$chart/values.yaml")
  [[ -f $chart/values-$stage.yaml ]] && values+=(--values "$chart/values-$stage.yaml")
  for route in ingress gateway; do
    if errors=$(helm template "$service" charts/app "${values[@]}" \
      --set "platform.stage=$stage" --set "platform.route=$route" 2>&1 >"$work/$stage-$route.yaml"); then
      printf '# stage: %s  route: %s\n' "$stage" "$route"
      cat "$work/$stage-$route.yaml"
      rendered+=("$stage $route")
    else
      { fail "$stage on $route"; hint "$errors"; } >&2
    fi
  done
done

exec >&2
section "$service through charts/app"
if git -C "$chart" rev-parse --git-dir >/dev/null 2>&1; then
  dirty=''
  if [[ -n $(git -C "$chart" status --porcelain .) ]]; then dirty=', uncommitted'; fi
  ok "$(printf '%-11s %s' values "$(git -C "$chart" rev-parse --abbrev-ref HEAD) at $(git -C "$chart" rev-parse --short HEAD)$dirty")"
fi
for entry in "${rendered[@]}"; do
  read -r stage route <<<"$entry"
  ok "$(printf '%-11s %-8s %s objects' "$stage" "$route" "$(awk '/^kind: /{n++} END{print n+0}' "$work/$stage-$route.yaml")")"
done

# What Helm can't check: the CRDs, the API server's own validation, whatever admission adds. The
# namespace is Argo CD's to pick, so the dry run uses the current one.
if kubectl cluster-info >/dev/null 2>&1; then
  for entry in "${rendered[@]}"; do
    read -r stage route <<<"$entry"
    if errors=$(kubectl apply --dry-run=server --filename "$work/$stage-$route.yaml" 2>&1 >/dev/null); then
      ok "$(printf '%-11s %-8s the API server accepts it' "$stage" "$route")"
    else
      fail "$stage on $route"
      hint "$errors"
    fi
  done
else
  warn "no cluster: only Helm checked these"
fi

if ((problems > 0)); then exit 1; fi
