# Optional settings (see .env.example).
set dotenv-load

cluster_name := "back"
# The Gateway API version Traefik v3.7 is built against.
gateway_api_version := "v1.6.1"
# Traefik v3.7.13.
traefik_chart_version := "41.5.0"
# Argo CD v3.5.2, for the first install only; platform/apps/argocd.yaml owns it after that.
argocd_chart_version := "10.8.4"

# Same isolation as mise.toml: recipes only touch the lab cluster.
export KUBECONFIG := justfile_directory() / ".kube/config"
export ARGOCD_OPTS := "--config " + justfile_directory() / ".argocd/config" + " --grpc-web --plaintext"

[private]
default:
    @just --list --unsorted

# Create the cluster, the base layer and Argo CD, then wait for Argo CD to deliver the rest (idempotent)
up: preflight cluster gateway localstack argocd notifications wait check

# Check that this machine is ready for the lab (./setup.sh fixes what it can)
preflight:
    @./setup.sh --check

# Create the kind cluster (skipped if it already exists)
cluster:
    @mkdir -p .kube
    @kind get clusters 2>/dev/null | grep -qx {{cluster_name}} || kind create cluster --config cluster/kind.yaml
    @kind export kubeconfig --name {{cluster_name}}

# Install the Gateway API CRDs and Traefik (serves both Ingress and Gateway API)
gateway:
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{gateway_api_version}}/standard-install.yaml
    helm upgrade --install traefik oci://ghcr.io/traefik/helm/traefik --version {{traefik_chart_version}} \
        --namespace traefik --create-namespace --values cluster/traefik-values.yaml --wait

# Deploy LocalStack (last Community image, no auth token) and its DNS rule
localstack:
    kubectl apply -f cluster/localstack.yaml
    kubectl apply --server-side --force-conflicts -f cluster/coredns.yaml
    kubectl --namespace localstack rollout status deployment/localstack --timeout=5m

# Install Argo CD once and apply the root Application; from then on, Argo CD manages itself from Git
argocd:
    #!/usr/bin/env bash
    set -euo pipefail
    if kubectl --namespace argocd get application argocd >/dev/null 2>&1; then
        echo "Argo CD already manages itself: change platform/argocd/values.yaml and push instead"
    else
        helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version {{argocd_chart_version}} \
            --namespace argocd --create-namespace --values platform/argocd/values.yaml --wait
    fi
    kubectl apply -f platform/root.yaml

# Give Argo CD the GitHub App it uses to report deployments to GitHub (optional; reads .env)
notifications:
    @scripts/notifications.sh

# Wait until every Argo CD Application is synced and healthy (up to 10 minutes)
wait:
    @scripts/wait.sh

# Print the initial password of Argo CD's admin user
argocd-password:
    @kubectl --namespace argocd get secret argocd-initial-admin-secret --output jsonpath='{.data.password}' | base64 --decode && echo

# Log the argocd CLI in as admin
argocd-login:
    @argocd login argocd.localhost:80 --skip-test-tls --username admin --password "$(just argocd-password)"

# Print a token to log in to Headlamp (as its ServiceAccount, a cluster admin; valid for 24h)
headlamp-token:
    @kubectl --namespace headlamp create token headlamp --duration 24h

# Point the lab at your forks: replaces github.com/hvpaiva/ in platform/ with your account and commits
use-fork owner:
    @scripts/use-fork.sh {{owner}}

# Smoke-test the lab from the host
check:
    @scripts/check.sh

# Delete the cluster and everything in it
[confirm("Delete the 'back' kind cluster and everything in it? [y/N]")]
down:
    kind delete cluster --name {{cluster_name}}
