#!/usr/bin/env bash
# Renders one of the platform's APIs against the example request next to it and checks the result
# against the schemas it has to satisfy (just render <api>). No cluster: Docker runs the functions,
# and the schemas are downloaded once. With the lab running, the CRD Crossplane makes of the XRD is
# also put to the API server as a dry run. Everything but the manifests goes to stderr, and the
# manifests only once they pass, so `just render bucket > out.yaml` never writes a rejected render.
#
#   scripts/render.sh bucket                     what the Composition would create
#   scripts/render.sh cache -o observed.yaml     ... given resources that already exist
#   scripts/render.sh database -e secret.yaml    ... given resources it reads from the cluster
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

# Kinds a Composition can create that another operator defines, and the Application that installs it.
declare -A operators=([postgresql.cnpg.io]=platform/apps/cloudnative-pg.yaml)

api=${1:-}
dir=platform/apis/$api
if [[ ! -d $dir ]]; then
  echo "usage: $(basename "$0") <api> [crossplane composition render flags]" >&2
  echo "apis: $(cd platform/apis && printf '%s ' */ | tr -d /)" >&2
  exit 2
fi
shift

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

chart_crds() { # application
  local repo chart version cached
  read -r repo chart version < <(awk '$1 == "repoURL:" { r = $2 } $1 == "chart:" { c = $2 }
                                      $1 == "targetRevision:" { v = $2 } END { print r, c, v }' "$1")
  cached=.cache/schemas/$chart-$version.yaml
  if [[ ! -s $cached ]]; then
    waiting "downloading $chart $version for its schemas, only this once"
    mkdir -p "${cached%/*}"
    helm template "$chart" "$chart" --repo "$repo" --version "$version" --include-crds >"$work/chart.yaml" || exit 1
    awk 'function keep() { if (doc ~ /(^|\n)kind: CustomResourceDefinition\n/) printf "---\n%s", doc; doc = "" }
         /^---$/ { keep(); next } { doc = doc $0 "\n" } END { keep() }' "$work/chart.yaml" >"$cached.partial"
    mv "$cached.partial" "$cached"
  fi
  cp "$cached" "$schemas/"
}

# Validation needs every schema in one directory: the API's own, and the providers' for what it composes.
schemas=$work/schemas
mkdir "$schemas"
cp "$dir/definition.yaml" platform/crossplane/providers.yaml "$schemas/"
rendered=$work/rendered.yaml

# --include-full-xr keeps the request's own spec in the output, which the XRD's rules are checked against.
crossplane composition render "$dir/example.yaml" "$dir/composition.yaml" platform/crossplane/functions.yaml \
  --xrd "$dir/definition.yaml" --include-full-xr "$@" >"$rendered"
{
  section "What $api renders"
  # Two kinds can share a name here: the request's own, and the provider's it composes.
  awk '/^apiVersion: / { split($2, v, "/"); group = v[1] }
       /^kind: / { kind = $2 }
       /^  name: / && kind != "" { printf "  %-37s %s\n", group "/" kind, $2; kind = "" }' "$rendered"

  section "Checking $api against the schemas it has to satisfy"
  # The built-in schemas come from the Crossplane the cluster runs, read from its chart, not from `stable`.
  version=$(awk '/chart: crossplane/ { found = 1 }
                 found && /targetRevision:/ { print $2; exit }' platform/apps/crossplane.yaml)
  if [[ -z $version ]]; then
    fail "platform/apps/crossplane.yaml doesn't say which Crossplane the cluster runs"
    exit 1
  fi
  # What render adds of its own with -c and -r, the context and the results, has no schema.
  awk 'function keep() { if (doc != "" && doc !~ /(^|\n)apiVersion: render\.crossplane\.io\//) printf "---\n%s", doc; doc = "" }
       /^---$/ { keep(); next } { doc = doc $0 "\n" } END { keep() }' "$rendered" >"$work/resources.yaml"
  for group in "${!operators[@]}"; do
    if grep -q "^apiVersion: $group/" "$work/resources.yaml"; then chart_crds "${operators[$group]}"; fi
  done
  # Only what isn't already fine, plus the totals; a schema it doesn't satisfy is the answer, not a crash.
  status=0
  crossplane resource validate "$schemas" "$work/resources.yaml" --error-on-missing-schemas \
    --crossplane-image "xpkg.crossplane.io/crossplane/crossplane:v$version" 2>&1 |
    tee "$work/validation" | awk '!/^\[✓\]/ { print "  " $0 }' || status=$?
  if grep -q '^\[!\] could not find' "$work/validation"; then
    hint "a kind nothing here describes: its provider goes in platform/crossplane/providers.yaml, its operator in $0"
  fi
  ((status == 0)) || exit 1
  if kubectl cluster-info >/dev/null 2>&1; then
    crossplane xrd convert "$dir/definition.yaml" --output-file "$work/crd.yaml"
    # The XRD's uid can't be known offline, and an owner without one is invalid.
    if errors=$(kubectl patch --local --filename "$work/crd.yaml" --type json --output yaml \
      --patch '[{"op": "remove", "path": "/metadata/ownerReferences"}]' |
      kubectl apply --server-side --force-conflicts --field-manager just-render --dry-run=server --filename - 2>&1 >/dev/null); then
      ok "the API server accepts the CRD Crossplane makes of the XRD"
    else
      fail "the API server refuses the CRD Crossplane makes of the XRD"
      hint "$errors"
      exit 1
    fi
  else
    warn "no cluster: the CRD Crossplane makes of the XRD wasn't put to the API server"
  fi
} >&2

cat "$rendered"
