#!/usr/bin/env bash
# Checks what this repository defines as CI does, and what it can against the API server when the lab runs (just test).
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
source scripts/schemas.sh

all=(scripts health apis services platform)
areas=("$@")
if ((${#areas[@]} == 0)); then areas=("${all[@]}"); fi
for area in "${areas[@]}"; do
  if [[ " ${all[*]} " != *" $area "* ]]; then
    echo "usage: $(basename "$0") [area...]" >&2
    echo "areas: ${all[*]}" >&2
    exit 2
  fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cluster=false
if kubectl cluster-info >/dev/null 2>&1; then cluster=true; fi

quiet() { "$@" >/dev/null; }

attempt() { # label command...
  local label=$1
  shift
  spin "$label" "$@" && return 0
  fail "$label"
  if [[ -n $spun ]]; then details <<<"$spun"; fi
  return 1
}

resources() { grep -o 'Total [0-9]* resources' <<<"$spun" | awk '{ print $2 " resources" }'; }

scripts_area() {
  local scripts=(scripts/*.sh setup.sh) workflows=(.github/workflows/*.yaml)
  section "Scripts and workflows"
  if attempt "shellcheck" shellcheck --external-sources "${scripts[@]}"; then
    ok "shellcheck finds nothing in the ${#scripts[@]} scripts"
  fi
  if attempt "actionlint" actionlint "${workflows[@]}"; then
    ok "actionlint finds nothing in the ${#workflows[@]} workflows"
  fi
  # A script nobody can run fails where it is called, not here, and a workflow step can swallow that.
  local script unrunnable=()
  for script in "${scripts[@]}"; do
    [[ -x $script ]] && continue
    # One that another sources is a library: it is read, not run.
    grep -q "source $script" "${scripts[@]}" && continue
    unrunnable+=("$script")
  done
  if ((${#unrunnable[@]} > 0)); then
    fail "not executable: ${unrunnable[*]}"
    hint "chmod +x ${unrunnable[*]}"
  else
    ok "every script can be run"
  fi
}

argocd_cm() { # output
  local repository chart version archive
  IFS=$'\t' read -r repository chart version < <(yq \
    '.spec.sources[] | select(.chart == "argo-cd") | [.repoURL, .chart, .targetRevision] | @tsv' platform/apps/argocd.yaml)
  archive=$(chart_archive "$repository" "$chart" "$version") || return
  helm template argocd "$archive" --namespace argocd --kube-version "$(kube_version)" \
    --values platform/argocd/values.yaml | yq 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm")' >"$1" || return
  [[ -s $1 ]]
}

health_area() {
  local fixture expected name answer status message
  section "Argo CD's health checks"
  attempt "argocd-cm, from platform/argocd/values.yaml" argocd_cm "$work/argocd-cm.yaml" || return 0
  for fixture in tests/health/*/*.yaml; do
    expected=${fixture%/*}
    expected=${expected##*/}
    name=${fixture#tests/health/}
    name=${name%.yaml}
    answer=$(argocd admin settings resource-overrides health "$fixture" --argocd-cm-path "$work/argocd-cm.yaml" 2>&1) || true
    status=$(awk '$1 == "STATUS:" { print tolower($2) }' <<<"$answer")
    message=$(sed -n 's/^MESSAGE: //p' <<<"$answer")
    if [[ -z $status ]]; then
      fail "$name: no health check answers for $(yq '.apiVersion + ", Kind=" + .kind' "$fixture")"
      details < <(grep -v '^{' <<<"$answer")
    elif [[ $status != "$expected" ]]; then
      fail "$name: $status${message:+, $message}"
    else
      ok "$name${message:+: $message}"
    fi
  done
  if $cluster; then
    if attempt "argocd-cm, put to the API server" kubectl apply --server-side --dry-run=server --force-conflicts \
      --field-manager just-test --filename "$work/argocd-cm.yaml"; then
      ok "the API server accepts argocd-cm"
    fi
  fi
}

apis_area() {
  local definition api folder scenario scenarios label
  section "The platform's APIs"
  if ! docker info >/dev/null 2>&1; then
    fail "Docker isn't reachable here, and the Compositions' functions run in it: ./setup.sh says what's missing"
    return 0
  fi
  for definition in platform/apis/*/definition.yaml; do
    api=${definition%/definition.yaml}
    api=${api##*/}
    scenarios=('')
    for folder in "tests/apis/$api"/*/; do
      if [[ -d $folder ]]; then
        folder=${folder%/}
        scenarios+=("${folder##*/}")
      fi
    done
    for scenario in "${scenarios[@]}"; do
      label=$api${scenario:+, $scenario}
      if attempt "$label" quiet scripts/render.sh "$api" ${scenario:+"$scenario"}; then
        ok "$(printf '%-24s %s' "$label" "$(resources)")"
      fi
    done
  done
  if ! $cluster; then warn "no cluster: the CRDs Crossplane makes of the XRDs weren't put to the API server"; fi
}

service_check() { # chart label
  if attempt "$2" quiet scripts/render-service.sh "$1"; then
    ok "$(printf '%-36s %s' "$2" "$(awk '/objects match their schemas/ { n++; objects += $(NF - 4) }
      END { print n " renders, " objects " objects" }' <<<"$spun")")"
  fi
}

services_area() {
  local chart services service repository branch clone
  section "Services through charts/app"
  for chart in tests/services/*/; do
    service_check "${chart%/}" "${chart%/}"
  done
  # What the ApplicationSet deploys, read from the branches it deploys it from.
  mapfile -t services < <(yq '[.. | select(tag == "!!map" and has("repo") and has("branch"))] | .[] | [.repo, .branch] | @tsv' \
    platform/apps/applicationset.yaml | sort -u)
  for service in "${services[@]}"; do
    IFS=$'\t' read -r repository branch <<<"$service"
    clone=$work/services/$(basename "$repository" .git)-$branch
    attempt "$repository at $branch" git clone --quiet --depth 1 --branch "$branch" "$repository" "$clone" || continue
    for chart in "$clone"/charts/*/; do
      chart=${chart%/}
      service_check "$chart" "$(basename "$repository" .git) at $branch, charts/${chart##*/}"
    done
  done
  if ! $cluster; then warn "no cluster: none of it was put to the API server"; fi
}

# In Argo CD's order: value files, then the values the Application writes, then parameters.
render_chart() { # name namespace source application this-repository
  local repository chart version release archive file ref path key value args=()
  IFS=$'\t' read -r repository chart version release < <(yq "[.repoURL, .chart, .targetRevision, .helm.releaseName // \"$1\"] | @tsv" "$3")
  archive=$(chart_archive "$repository" "$chart" "$version") || return
  while IFS= read -r file; do
    if [[ $file != \$*/* ]]; then
      echo "$file: a value file from inside the chart, which this doesn't render"
      return 1
    fi
    ref=${file%%/*}
    path=${file#*/}
    if [[ $(yq "(.spec.sources // [.spec.source])[] | select(.ref == \"${ref#\$}\") | .repoURL" "$4") != "$5" ]]; then
      echo "$file: a value file from another repository, which this doesn't render"
      return 1
    fi
    args+=(--values "$path")
  done < <(yq '.helm.valueFiles // [] | .[]' "$3")
  yq '.helm.valuesObject // {}' "$3" >"$3.values" || return
  args+=(--values "$3.values")
  while IFS=$'\t' read -r key value; do
    args+=(--set "$key=$value")
  done < <(yq '.helm.parameters // [] | .[] | [.name, .value] | @tsv' "$3")
  if [[ -n $2 ]]; then args+=(--namespace "$2"); fi
  helm template "$release" "$archive" --include-crds --kube-version "$(kube_version)" "${args[@]}"
}

render_folder() { # source this-repository
  local path depth=(-maxdepth 1) filters=() exclude file
  if [[ $(yq '.repoURL' "$1") != "$2" ]]; then
    echo "$(yq '.repoURL' "$1"): a folder from another repository, which this doesn't render"
    return 1
  fi
  path=$(yq '.path' "$1")
  if [[ $(yq '.directory.recurse // false' "$1") == true ]]; then depth=(); fi
  exclude=$(yq '.directory.exclude // ""' "$1")
  if [[ -n $exclude ]]; then filters=(-not -path "$path/$exclude"); fi
  while IFS= read -r file; do
    printf -- '---\n'
    cat "$file"
    echo
  done < <(find "$path" "${depth[@]}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) "${filters[@]}" | sort)
}

render_application() { # file name this-repository output
  local application=$work/applications/$2 count i
  mkdir -p "$application"
  yq "select(.kind == \"Application\" and .metadata.name == \"$2\")" "$1" >"$application/application.yaml" || return
  yq '.spec.destination.namespace // ""' "$application/application.yaml" >"$application/namespace" || return
  count=$(yq '(.spec.sources // [.spec.source]) | length' "$application/application.yaml")
  : >"$4"
  for ((i = 0; i < count; i++)); do
    yq "(.spec.sources // [.spec.source])[$i]" "$application/application.yaml" >"$application/source-$i.yaml" || return
    if [[ $(yq '.chart // ""' "$application/source-$i.yaml") != "" ]]; then
      render_chart "$2" "$(cat "$application/namespace")" "$application/source-$i.yaml" \
        "$application/application.yaml" "$3" >>"$4" || return
    elif [[ $(yq '.path // ""' "$application/source-$i.yaml") != "" ]]; then
      render_folder "$application/source-$i.yaml" "$3" >>"$4" || return
    elif [[ $(yq '.ref // ""' "$application/source-$i.yaml") == "" ]]; then
      echo "source $i is neither a chart, a folder nor a reference to value files, which this doesn't render"
      return 1
    fi
  done
}

render_base_layer() { # output
  local reference version archive
  reference=$(awk 'match($0, /oci:\/\/[^ ]+/) { print substr($0, RSTART + 6, RLENGTH - 6); exit }' scripts/base.sh)
  version=$(awk -F= '$1 == "traefik_chart_version" { print $2 }' scripts/base.sh)
  archive=$(chart_archive "${reference%/*}" "${reference##*/}" "$version") || return
  mkdir -p "$work/applications/base-layer"
  echo traefik >"$work/applications/base-layer/namespace"
  {
    helm template traefik "$archive" --namespace traefik --include-crds --kube-version "$(kube_version)" \
      --values cluster/traefik-values.yaml || return
    printf -- '---\n'
    cat cluster/cloud.yaml
    printf -- '---\n'
    cat cluster/coredns.yaml
  } >"$1"
}

platform_schemas() { # directory
  own_schemas "$1"
  # The inputs written inside Compositions are the functions' kinds.
  cp platform/crossplane/functions.yaml "$1/"
  cat "$work"/rendered/*.yaml | yq 'select(.kind == "CustomResourceDefinition")' >"$1/crds.yaml" || return
  gateway_api_crds >"$1/gateway-api.yaml"
}

# Each object goes to the namespace Argo CD would use, and a kind or namespace not created yet can't be asked about.
dry_run() { # name
  local destination namespace namespaces said='' unmet missing
  destination=$(cat "$work/applications/$1/namespace")
  namespaces=$(yq ea '[select(tag == "!!map") | .metadata.namespace // ""] | unique | .[]' "$work/rendered/$1.yaml") || return
  mapfile -t namespaces <<<"$namespaces"
  for namespace in "${namespaces[@]}"; do
    yq "select(tag == \"!!map\" and (.metadata.namespace // \"\") == \"$namespace\")" "$work/rendered/$1.yaml" \
      >"$work/dry-run.yaml" || return
    said+=$(kubectl apply --server-side --dry-run=server --force-conflicts --field-manager just-test \
      --namespace "${namespace:-${destination:-default}}" --filename "$work/dry-run.yaml" 2>&1)$'\n' || true
  done
  unmet=$(grep -v -E '\(server dry run\)$|no matches for kind|ensure CRDs are installed first|namespaces "[^"]+" not found|^$' <<<"$said" || true)
  if [[ -n $unmet ]]; then
    echo "$unmet"
    return 1
  fi
  missing=$(grep -o -E 'no matches for kind "[^"]+"|namespaces "[^"]+" not found' <<<"$said" |
    sed -E 's/no matches for kind "([^"]+)"/kind \1/; s/namespaces "([^"]+)" not found/namespace \1/' | sort -u | paste -sd, -)
  if [[ -n $missing ]]; then echo "except what the cluster doesn't have yet: ${missing//,/, }"; fi
}

platform_area() {
  local this file name names rendered=()
  section "What Argo CD applies, and the base layer under it"
  this=$(yq '.spec.source.repoURL' platform/root.yaml)
  mkdir -p "$work/rendered"
  for file in platform/root.yaml platform/apps/*.yaml; do
    mapfile -t names < <(yq ea '[select(.kind == "Application") | .metadata.name] | .[]' "$file")
    for name in "${names[@]}"; do
      if attempt "$name" render_application "$file" "$name" "$this" "$work/rendered/$name.yaml"; then
        rendered+=("$name")
      fi
    done
  done
  if attempt "the base layer" render_base_layer "$work/rendered/base-layer.yaml"; then rendered+=(base-layer); fi
  attempt "the schemas all of it defines" platform_schemas "$work/schemas" || return 0
  for name in "${rendered[@]}"; do
    if attempt "$name" validate "$work/schemas" "$work/rendered/$name.yaml"; then
      ok "$(printf '%-22s %s' "$name" "$(resources)")"
    fi
  done
  if $cluster; then
    for name in "${rendered[@]}"; do
      if attempt "$name, put to the API server" dry_run "$name"; then
        ok "$(printf '%-22s %s' "$name" "the API server accepts it${spun:+, $spun}")"
      fi
    done
  else
    warn "no cluster: none of it was put to the API server"
  fi
}

for area in "${areas[@]}"; do
  "${area}_area"
done
if ((problems > 0)); then exit 1; fi
