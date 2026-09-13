#!/usr/bin/env bash
# The layer `just up` installs before Argo CD takes over, in the order it installs them: the cluster,
# the Gateway API and Traefik, LocalStack, and Argo CD's own first install. Each step reports one
# line, and keeps the tool's output for when it fails.
#
#   scripts/base.sh cluster      the kind cluster, with kubectl pointed at it (just cluster)
#   scripts/base.sh gateway      the Gateway API CRDs and Traefik (just gateway)
#   scripts/base.sh localstack   LocalStack and the DNS rule it needs (just localstack)
#   scripts/base.sh argocd       Argo CD, its projects and the root Application (just argocd)
#   scripts/base.sh down         delete the cluster and the lab's contexts (just down)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

cluster_name=back
# The Gateway API version Traefik v3.7 is built against.
gateway_api_version=v1.6.1
# Traefik v3.7.13.
traefik_chart_version=41.5.0
# Argo CD v3.5.2, for the first install only; platform/apps/argocd.yaml owns it after that.
argocd_chart_version=10.8.4

case ${1:-} in
  plan)
    section "Bringing the lab up"
    hint "this machine, the cluster, Traefik, LocalStack, Argo CD, the identities and notifications,"
    hint "then waiting for Argo CD to deliver the platform and checking it answers: about four minutes"
    hint "what each step's own commands print goes to .logs/lab.log, run after run"
    ;;
  cluster)
    section "Cluster"
    mkdir -p .kube
    if kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
      ok "the $cluster_name cluster is already running"
    else
      hint "the first run pulls the node image, so this one takes a minute or two"
      run "the $cluster_name cluster" kind create cluster --config cluster/kind.yaml || exit 1
    fi
    run "kubectl and helm point at the lab, and nothing else" \
      kind export kubeconfig --name "$cluster_name" || exit 1
    ;;
  gateway)
    section "Gateway API and Traefik"
    run "Gateway API $gateway_api_version" kubectl apply --server-side \
      --filename "https://github.com/kubernetes-sigs/gateway-api/releases/download/$gateway_api_version/standard-install.yaml" || exit 1
    run "Traefik, chart $traefik_chart_version, serving Ingress and Gateway API" \
      helm upgrade --install traefik oci://ghcr.io/traefik/helm/traefik --version "$traefik_chart_version" \
      --namespace traefik --create-namespace --values cluster/traefik-values.yaml --wait || exit 1
    ;;
  localstack)
    section "LocalStack"
    run "LocalStack" kubectl apply --filename cluster/localstack.yaml || exit 1
    run "DNS for its S3 Control endpoint" \
      kubectl apply --server-side --force-conflicts --filename cluster/coredns.yaml || exit 1
    run "LocalStack answering" \
      kubectl --namespace localstack rollout status deployment/localstack --timeout=5m || exit 1
    ;;
  argocd)
    section "Argo CD"
    if kubectl --namespace argocd get application argocd >/dev/null 2>&1; then
      ok "Argo CD already manages itself: change platform/argocd/values.yaml and push instead"
    else
      run "Argo CD, chart $argocd_chart_version" helm upgrade --install argocd argo-cd \
        --repo https://argoproj.github.io/argo-helm --version "$argocd_chart_version" \
        --namespace argocd --create-namespace --values platform/argocd/values.yaml --wait || exit 1
    fi
    run "the projects and the root Application" \
      kubectl apply --filename platform/apps/projects.yaml --filename platform/root.yaml || exit 1
    ;;
  down)
    section "Deleting the lab"
    run "the $cluster_name cluster and everything in it" \
      kind delete cluster --name "$cluster_name" || exit 1
    run "the lab's kubectl contexts" scripts/identities.sh remove || exit 1
    ;;
  *)
    echo "usage: $(basename "$0") [plan|cluster|gateway|localstack|argocd|down]" >&2
    exit 2
    ;;
esac
