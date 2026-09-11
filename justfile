# Lab lifecycle. Run `just` to list the recipes.

cluster_name := "back"
# The Gateway API version Traefik v3.7 is built against.
gateway_api_version := "v1.6.1"
# Traefik v3.7.13.
traefik_chart_version := "41.5.0"

# Same isolation as mise.toml: recipes only ever touch the lab cluster.
export KUBECONFIG := justfile_directory() / ".kube/config"

[private]
default:
    @just --list --unsorted

# Create the cluster and install the base layer (idempotent)
up: preflight cluster gateway localstack check

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

# Deploy LocalStack (last Community image, no auth token)
localstack:
    kubectl apply -f cluster/localstack.yaml
    kubectl --namespace localstack rollout status deployment/localstack --timeout=5m

# Smoke-test the base layer from the host
check:
    @curl -fsS -o /dev/null http://traefik.localhost/dashboard/ && echo "gateway     ok  http://traefik.localhost/dashboard/"
    @curl -fsS http://localhost:4566/_localstack/health | jq -r '"localstack  ok  \(.edition) \(.version), http://localhost:4566"'

# Delete the cluster and everything in it
[confirm("Delete the 'back' kind cluster and everything in it? [y/N]")]
down:
    kind delete cluster --name {{cluster_name}}
