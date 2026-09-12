#!/usr/bin/env bash
# Renders a service through the platform's chart, for every stage, the way the delivery workflow
# validates a pull request (just render-service [path]). The manifests go to stdout and the verdict
# to stderr, and with the lab running each stage is also put to the API server as a dry run.
#
#   scripts/render-service.sh                            ../back-hello/charts/hello
#   scripts/render-service.sh ../back-other/charts/api   another service, from its chart folder
set -euo pipefail
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
  if errors=$(helm template "$service" charts/app "${values[@]}" --set "platform.stage=$stage" 2>&1 >"$work/$stage.yaml"); then
    printf '# stage: %s\n' "$stage"
    cat "$work/$stage.yaml"
    rendered+=("$stage")
  else
    { fail "$stage"; hint "$errors"; } >&2
  fi
done

exec >&2
section "$service through charts/app"
for stage in "${rendered[@]}"; do
  ok "$(printf '%-11s %s objects' "$stage" "$(awk '/^kind: /{n++} END{print n+0}' "$work/$stage.yaml")")"
done

# What Helm can't check: the CRDs, the API server's own validation, whatever admission adds. The
# namespace is Argo CD's to pick, so the dry run uses the current one.
if kubectl cluster-info >/dev/null 2>&1; then
  for stage in "${rendered[@]}"; do
    if errors=$(kubectl apply --dry-run=server --filename "$work/$stage.yaml" 2>&1 >/dev/null); then
      ok "$(printf '%-11s the API server accepts it' "$stage")"
    else
      fail "$stage"
      hint "$errors"
    fi
  done
else
  warn "no cluster: only Helm checked these"
fi

((problems == 0))
