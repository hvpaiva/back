# Lab lifecycle. Run `just` to list the recipes.

# Optional settings, such as the GitHub App for deploy statuses (see .env.example).
set dotenv-load

cluster_name := "back"
# The Gateway API version Traefik v3.7 is built against.
gateway_api_version := "v1.6.1"
# Traefik v3.7.13.
traefik_chart_version := "41.5.0"
# Argo CD v3.5.2. Only used for the first install: afterwards the version in
# platform/apps/argocd.yaml is the one that counts.
argocd_chart_version := "10.8.4"

# Same isolation as mise.toml: recipes only ever touch the lab cluster.
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
    # The app of apps: delivers every Application in platform/apps/, Argo CD's own included.
    kubectl apply -f platform/root.yaml

# Give Argo CD the GitHub App it uses to report deployments to GitHub (optional; reads .env)
notifications:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z ${GITHUB_APP_ID:-} ]]; then
        echo "No GitHub App in .env: Argo CD won't report deployments to GitHub (optional, see the README)"
        exit 0
    fi
    key_file=${GITHUB_APP_PRIVATE_KEY_FILE:?set GITHUB_APP_PRIVATE_KEY_FILE in .env}
    key_file=${key_file/#\~/$HOME}
    # The key is read from disk into the cluster; it never goes into Git.
    kubectl --namespace argocd create secret generic argocd-notifications-secret \
        --from-literal=github-appID="$GITHUB_APP_ID" \
        --from-literal=github-installationID="${GITHUB_APP_INSTALLATION_ID:?set GITHUB_APP_INSTALLATION_ID in .env}" \
        --from-file=github-privateKey="$key_file" \
        --dry-run=client --output yaml | kubectl apply --filename -
    echo "GitHub App stored: Argo CD reports the next deployments to GitHub"

# Wait until every Argo CD Application is synced and healthy (up to 10 minutes)
wait:
    #!/usr/bin/env bash
    set -euo pipefail
    # Applications appear in waves (root creates the others), so a single
    # snapshot isn't enough: require two healthy checks in a row.
    healthy_checks=0
    for _ in $(seq 120); do
        pending=$(kubectl --namespace argocd get applications --no-headers \
            -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null |
            awk '$2 != "Synced" || $3 != "Healthy" { print $1 }' | paste -sd ' ' -)
        count=$(kubectl --namespace argocd get applications --no-headers 2>/dev/null | wc -l)
        if [[ -z $pending && $count -gt 1 ]]; then
            healthy_checks=$((healthy_checks + 1))
            if ((healthy_checks == 2)); then
                echo "all $count Applications are synced and healthy"
                exit 0
            fi
        else
            healthy_checks=0
            echo "waiting for: ${pending:-the Applications root creates}"
        fi
        sleep 5
    done
    echo "gave up after 10 minutes; see http://argocd.localhost or: kubectl -n argocd get applications" >&2
    exit 1

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
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(git grep -l 'github.com/hvpaiva/' -- platform || true)
    if [[ -z $files ]]; then
        echo "platform/ doesn't reference github.com/hvpaiva/ anymore; nothing to do"
        exit 0
    fi
    # perl rather than sed -i, which differs between GNU and BSD.
    perl -pi -e 's#github\.com/hvpaiva/#github.com/{{owner}}/#g' $files
    git commit --quiet -m "chore: point the lab at github.com/{{owner}}" -- $files
    echo "Committed. Next: git push, then just argocd, so Argo CD reads your fork."

# Smoke-test the lab from the host
check:
    @curl -fsS -o /dev/null http://traefik.localhost/dashboard/ && echo "gateway     ok  http://traefik.localhost/dashboard/"
    @curl -fsS http://localhost:4566/_localstack/health | jq -r '"localstack  ok  \(.edition) \(.version), http://localhost:4566"'
    @curl -fsS http://argocd.localhost/api/version | jq -r '"argocd      ok  \(.Version | split("+")[0]), http://argocd.localhost (user admin, password: just argocd-password)"'
    @curl -fsS -o /dev/null http://headlamp.localhost/ && echo "headlamp    ok  http://headlamp.localhost (token: just headlamp-token)"
    @kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io --output json | jq -er '.items | if length > 0 and all(any(.status.conditions[]?; .type == "Healthy" and .status == "True")) then "crossplane  ok  \(map(select(.kind == "Provider")) | length) providers and \(map(select(.kind == "Function")) | length) functions healthy (kubectl get providers,functions)" else error("some Crossplane packages are not healthy: kubectl get providers,functions") end'
    @curl -fsS http://hello.staging.localhost/api/info | jq -r '"hello       ok  \(.version) in staging, http://hello.staging.localhost"'
    @curl -fsS http://hello.localhost/api/info | jq -r '"hello       ok  \(.version) in production, http://hello.localhost"'

# Delete the cluster and everything in it
[confirm("Delete the 'back' kind cluster and everything in it? [y/N]")]
down:
    kind delete cluster --name {{cluster_name}}
