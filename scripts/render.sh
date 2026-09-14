#!/usr/bin/env bash
# Renders one of the platform's APIs against the example request next to it and checks the result
# against the schemas it has to satisfy (just render <api>). No cluster: Docker runs the functions,
# and the providers' schemas are downloaded once. Everything but the manifests goes to stderr, and the
# manifests only once they pass, so `just render bucket > out.yaml` never writes a rejected render.
#
#   scripts/render.sh bucket                     what the Composition would create
#   scripts/render.sh cache -o observed.yaml     ... given resources that already exist
#   scripts/render.sh database -e secret.yaml    ... given resources it reads from the cluster
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

api=${1:-}
dir=platform/apis/$api
if [[ ! -d $dir ]]; then
  echo "usage: $(basename "$0") <api> [crossplane render flags]" >&2
  echo "apis: $(cd platform/apis && printf '%s ' */ | tr -d /)" >&2
  exit 2
fi
shift

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Validation needs every schema in one directory: the API's own, and the providers' for what it composes.
cp "$dir/definition.yaml" platform/crossplane/providers.yaml "$work/"
rendered=$work/rendered.yaml

# --include-full-xr keeps the request's own spec in the output, which the XRD's rules are checked against.
crossplane render "$dir/example.yaml" "$dir/composition.yaml" platform/crossplane/functions.yaml \
  --xrd "$dir/definition.yaml" --include-full-xr "$@" >"$rendered"
{
  section "What $api renders"
  # Two kinds can share a name here: the request's own, and the provider's it composes.
  awk '/^apiVersion: / { split($2, v, "/"); group = v[1] }
       /^kind: / { kind = $2 }
       /^  name: / && kind != "" { printf "  %-37s %s\n", group "/" kind, $2; kind = "" }' "$rendered"

  section "Checking $api against the API's and the providers' schemas"
  # The built-in schemas come from the Crossplane the cluster runs, read from its chart, not from `stable`.
  version=$(awk '/chart: crossplane/ { found = 1 }
                 found && /targetRevision:/ { print $2; exit }' platform/apps/crossplane.yaml)
  if [[ -z $version ]]; then
    fail "platform/apps/crossplane.yaml doesn't say which Crossplane the cluster runs"
    exit 1
  fi
  # Only what isn't already fine, plus the totals; a schema it doesn't satisfy is the answer, not a crash.
  crossplane resource validate "$work" "$rendered" \
    --crossplane-image "xpkg.crossplane.io/crossplane/crossplane:v$version" |
    awk '!/^\[✓\]/ { print "  " $0 }' || exit 1
} >&2

cat "$rendered"
