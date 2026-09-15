#!/usr/bin/env bash
# Renders a service through the chart for every stage, as CI validates a pull request, and checks it against its schemas (just render-service).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
source scripts/schemas.sh

chart=${1:-../back-hello/charts/hello}
chart=${chart%/}
if [[ ! -f $chart/values.yaml ]]; then
  echo "usage: $(basename "$0") <path to a service's chart folder>" >&2
  echo "no values.yaml in $chart" >&2
  exit 2
fi
service=$(basename "$chart")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
renders=()
declare -A problem=()

for stage in staging production; do
  values=(--values "$chart/values.yaml")
  [[ -f $chart/values-$stage.yaml ]] && values+=(--values "$chart/values-$stage.yaml")
  for route in ingress gateway; do
    renders+=("$stage $route")
    if ! errors=$(helm template "$service" charts/app "${values[@]}" \
      --set "platform.stage=$stage" --set "platform.route=$route" 2>&1 >"$work/$stage-$route.yaml"); then
      problem["$stage $route"]=${errors:-helm failed without saying why}
    fi
  done
done

cat "$work"/*-*.yaml >"$work/all.yaml"
schemas_for "$work/all.yaml" "$work/schemas"
for render in "${renders[@]}"; do
  [[ -z ${problem[$render]:-} ]] || continue
  read -r stage route <<<"$render"
  if errors=$(validate "$work/schemas" "$work/$stage-$route.yaml"); then
    printf '# stage: %s  route: %s\n' "$stage" "$route"
    cat "$work/$stage-$route.yaml"
  else
    problem[$render]=$errors
  fi
done

exec >&2
section "$service through charts/app"
if git -C "$chart" rev-parse --git-dir >/dev/null 2>&1; then
  dirty=''
  if [[ -n $(git -C "$chart" status --porcelain .) ]]; then dirty=', uncommitted'; fi
  ok "$(printf '%-11s %s' values "$(git -C "$chart" rev-parse --abbrev-ref HEAD) at $(git -C "$chart" rev-parse --short HEAD)$dirty")"
fi
for render in "${renders[@]}"; do
  read -r stage route <<<"$render"
  if [[ -n ${problem[$render]:-} ]]; then
    fail "$(printf '%-11s %s' "$stage" "$route")"
    details <<<"${problem[$render]}"
  else
    ok "$(printf '%-11s %-8s %s objects match their schemas' "$stage" "$route" "$(awk '/^kind: /{n++} END{print n+0}' "$work/$stage-$route.yaml")")"
  fi
done

# The namespace is Argo CD's to pick, so the dry run uses the current one.
if kubectl cluster-info >/dev/null 2>&1; then
  for render in "${renders[@]}"; do
    [[ -z ${problem[$render]:-} ]] || continue
    read -r stage route <<<"$render"
    if errors=$(kubectl apply --dry-run=server --filename "$work/$stage-$route.yaml" 2>&1 >/dev/null); then
      ok "$(printf '%-11s %-8s the API server accepts it' "$stage" "$route")"
    else
      fail "$(printf '%-11s %s' "$stage" "$route")"
      hint "$errors"
    fi
  done
else
  warn "no cluster: none of it was put to the API server"
fi

if ((problems > 0)); then exit 1; fi
