#!/usr/bin/env bash
# Renders one of the platform's APIs against the example request next to it, or in one of its scenarios
# under tests/apis/, and checks the result against the schemas it has to satisfy (just render <api>
# [scenario]). No cluster: Docker runs the functions, and the schemas are downloaded once. With the lab
# running, the CRD Crossplane makes of the XRD is also put to the API server as a dry run. Everything but
# the manifests goes to stderr, and the manifests only once they pass, so `just render bucket > out.yaml`
# never writes a rejected render.
#
#   scripts/render.sh bucket                     what the Composition would create
#   scripts/render.sh database backed-up         ... in one of its scenarios, from tests/apis/database/
#   scripts/render.sh cache -o observed.yaml     ... given resources that already exist
#   scripts/render.sh database -e secret.yaml    ... given resources it reads from the cluster
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
source scripts/schemas.sh

api=${1:-}
dir=platform/apis/$api
if [[ -z $api || ! -d $dir ]]; then
  echo "usage: $(basename "$0") <api> [scenario] [crossplane composition render flags]" >&2
  echo "apis: $(cd platform/apis && printf '%s ' */ | tr -d /)" >&2
  exit 2
fi
shift

request=$dir/example.yaml
title=$api
given=()
if [[ ${1:-} != "" && $1 != -* ]]; then
  scenario=tests/apis/$api/$1
  if [[ ! -d $scenario ]]; then
    echo "no scenario $1 for $api in tests/apis/$api/" >&2
    echo "scenarios: $(for found in "tests/apis/$api"/*/; do [[ -d $found ]] && basename "$found"; done | paste -sd ' ' -)" >&2
    exit 2
  fi
  if [[ -f $scenario/request.yaml ]]; then request=$scenario/request.yaml; fi
  if [[ -f $scenario/observed.yaml ]]; then given+=(--observed-resources "$scenario/observed.yaml"); fi
  if [[ -f $scenario/required.yaml ]]; then given+=(--required-resources "$scenario/required.yaml"); fi
  title="$api, $1"
  shift
fi

version=$(crossplane_version)
if [[ -z $version ]]; then
  echo "platform/apps/crossplane.yaml doesn't say which Crossplane the cluster runs" >&2
  exit 1
fi
engine=xpkg.crossplane.io/crossplane/crossplane:v$version
mapfile -t images < <(yq ea '[select(.kind == "Function") | .spec.package] | .[]' platform/crossplane/functions.yaml)
# Render pulls what's missing within its one-minute timeout, which a slow registry runs out of.
for image in "$engine" "${images[@]}"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    waiting "pulling $image, only this once" >&2
    docker pull --quiet "$image" >/dev/null
  fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rendered=$work/rendered.yaml

# --include-full-xr keeps the request's own spec in the output, which the XRD's rules are checked against.
crossplane composition render "$request" "$dir/composition.yaml" platform/crossplane/functions.yaml \
  --xrd "$dir/definition.yaml" --include-full-xr --crossplane-image "$engine" "${given[@]}" "$@" >"$rendered"
{
  section "What $title renders"
  # Two kinds can share a name here: the request's own, and the provider's it composes.
  awk '/^apiVersion: / { split($2, v, "/"); group = v[1] }
       /^kind: / { kind = $2 }
       /^  name: / && kind != "" { printf "  %-37s %s\n", group "/" kind, $2; kind = "" }' "$rendered"

  section "Checking $title against the schemas it has to satisfy"
  # What render adds of its own with -c and -r, the context and the results, has no schema.
  awk 'function keep() { if (doc != "" && doc !~ /(^|\n)apiVersion: render\.crossplane\.io\//) printf "---\n%s", doc; doc = "" }
       /^---$/ { keep(); next } { doc = doc $0 "\n" } END { keep() }' "$rendered" >"$work/resources.yaml"
  schemas_for "$work/resources.yaml" "$work/schemas"
  # Only what isn't fine, plus the totals; a schema it doesn't satisfy is the answer, not a crash.
  status=0
  validate "$work/schemas" "$work/resources.yaml" | tee "$work/validation" | sed 's/^/  /' || status=$?
  if grep -q '^\[!\] could not find' "$work/validation"; then
    hint "a kind nothing here describes: its provider goes in platform/crossplane/providers.yaml, another project's in scripts/schemas.sh"
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
