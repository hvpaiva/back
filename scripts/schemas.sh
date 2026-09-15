# Schemas for checking what the lab renders, at the versions it pins, downloaded once into .cache/.
# shellcheck shell=bash

# Kinds another project defines, and the file that pins the version the cluster runs.
declare -A schema_sources=(
  [postgresql.cnpg.io]=platform/apps/cloudnative-pg.yaml
  [barmancloud.cnpg.io]=platform/apps/plugin-barman-cloud.yaml
  [argoproj.io]=platform/apps/argo-rollouts.yaml
  [gateway.networking.k8s.io]=scripts/base.sh
)

kube_version() {
  yq '.nodes[0].image | split("@") | .[0] | split(":") | .[1]' cluster/kind.yaml
}

crossplane_version() {
  yq '(.spec.sources // [.spec.source])[] | select(.chart == "crossplane") | .targetRevision' platform/apps/crossplane.yaml
}

chart_archive() { # repository chart version
  local archive=.cache/charts/$2-$3.tgz download
  if [[ ! -s $archive ]]; then
    download=$(mktemp -d)
    if [[ $1 == http* ]]; then
      helm pull "$2" --repo "$1" --version "$3" --destination "$download" >/dev/null || return
    else
      helm pull "oci://$1/$2" --version "$3" --destination "$download" >/dev/null || return
    fi
    mkdir -p "${archive%/*}"
    mv "$download"/*.tgz "$archive"
    rm -rf "$download"
  fi
  echo "$archive"
}

application_crds() { # application
  local repository chart version cached archive
  IFS=$'\t' read -r repository chart version < <(yq \
    '(.spec.sources // [.spec.source])[] | select(.chart) | [.repoURL, .chart, .targetRevision] | @tsv' "$1")
  cached=.cache/schemas/$chart-$version.yaml
  if [[ ! -s $cached ]]; then
    waiting "downloading $chart $version for its schemas, only this once" >&2
    archive=$(chart_archive "$repository" "$chart" "$version") || return
    mkdir -p "${cached%/*}"
    helm template "$chart" "$archive" --include-crds |
      yq 'select(.kind == "CustomResourceDefinition")' >"$cached.partial" || return
    mv "$cached.partial" "$cached"
  fi
  cat "$cached"
}

gateway_api_crds() {
  local version cached
  version=$(awk -F= '$1 == "gateway_api_version" { print $2 }' scripts/base.sh)
  cached=.cache/schemas/gateway-api-$version.yaml
  if [[ ! -s $cached ]]; then
    waiting "downloading the Gateway API $version for its schemas, only this once" >&2
    mkdir -p "${cached%/*}"
    curl -fsSL --max-time 60 --output "$cached.partial" \
      "https://github.com/kubernetes-sigs/gateway-api/releases/download/$version/standard-install.yaml" || return
    mv "$cached.partial" "$cached"
  fi
  cat "$cached"
}

own_schemas() { # directory
  local definition name
  mkdir -p "$1"
  for definition in platform/apis/*/definition.yaml; do
    name=${definition%/definition.yaml}
    cp "$definition" "$1/${name##*/}.yaml"
  done
  cp platform/crossplane/providers.yaml "$1/"
}

schemas_for() { # resources directory
  local group pin
  own_schemas "$2"
  for group in "${!schema_sources[@]}"; do
    grep -q "^apiVersion: $group/" "$1" || continue
    pin=${schema_sources[$group]}
    if [[ $pin == scripts/base.sh ]]; then
      gateway_api_crds >"$2/$group.yaml" || return
    else
      application_crds "$pin" >"$2/$group.yaml" || return
    fi
  done
}

validate() { # schemas resources
  local version
  # The built-in schemas come from the Crossplane the cluster runs, read from its chart, not from `stable`.
  version=$(crossplane_version)
  if [[ -z $version ]]; then
    echo "platform/apps/crossplane.yaml doesn't say which Crossplane the cluster runs"
    return 1
  fi
  crossplane resource validate "$1" "$2" --error-on-missing-schemas \
    --crossplane-image "xpkg.crossplane.io/crossplane/crossplane:v$version" 2>&1 | grep -v '^\[✓\]'
}
