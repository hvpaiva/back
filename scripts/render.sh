#!/usr/bin/env bash
# Renders one of the platform's APIs against the example request next to it and checks the result
# against the schemas it has to satisfy (just render <api>). No cluster: Docker runs the functions,
# and the providers' schemas are downloaded once. The rendered manifests go to stdout, everything
# else to stderr, so `just render bucket > out.yaml` keeps working.
#
#   scripts/render.sh bucket                     what the Composition would create
#   scripts/render.sh cache -o observed.yaml     ... given resources that already exist
#   scripts/render.sh database -e secret.yaml    ... given resources it reads from the cluster
set -euo pipefail
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
cat "$rendered"

exec >&2
section "Checking $api against the API's and the providers' schemas"
# Only what isn't already fine, plus the totals; a failure here fails the recipe.
crossplane resource validate "$work" "$rendered" | awk '!/^\[✓\]/ { print "  " $0 }'
