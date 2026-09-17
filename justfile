# Optional settings (see .env.example).
set dotenv-load

# Same isolation as mise.toml: recipes only touch the lab cluster.
export KUBECONFIG := justfile_directory() / ".kube/config"
export ARGOCD_OPTS := "--config " + justfile_directory() / ".argocd/config" + " --grpc-web --plaintext"

[private]
default:
    @just --list --unsorted

# kind's error for an unreachable Docker daemon doesn't say that's what's wrong.
[private]
docker-ready:
    @docker info >/dev/null 2>&1 || { echo "Docker isn't reachable here: ./setup.sh says what's missing" >&2; exit 1; }

# Create the cluster, the base layer and Argo CD, then wait for Argo CD to deliver the rest (idempotent)
up: plan preflight cluster gateway cloud argocd identities github-app wait check

# What `just up` is about to do, and roughly how long it takes.
[private]
plan:
    @scripts/base.sh plan

# Check that this machine is ready for the lab (./setup.sh fixes what it can)
preflight:
    @./setup.sh --check

# Create the kind cluster (skipped if it already exists)
cluster: docker-ready
    @scripts/base.sh cluster

# Install the Gateway API CRDs and Traefik (serves both Ingress and Gateway API)
gateway:
    @scripts/base.sh gateway

# Deploy the lab's cloud account (MiniStack, standing in for AWS) and its DNS rule
cloud:
    @scripts/base.sh cloud

# Install Argo CD once and apply the projects and the root Application; from then on, Argo CD manages itself from Git
argocd:
    @scripts/base.sh argocd

# Give dev and platform-admin a kubectl context and an Argo CD password (idempotent)
identities:
    @scripts/identities.sh

# Give Argo CD and Kargo the GitHub App they report deployments and push promotions with (reads .env)
github-app:
    @scripts/github-app.sh

# Wait until every Argo CD Application is synced and healthy (up to 10 minutes)
wait:
    @scripts/wait.sh

# Print the Argo CD password of platform-admin or dev
argocd-password user="platform-admin":
    @kubectl --namespace argocd get secret argocd-account-passwords --output jsonpath='{.data.{{user}}}' | base64 --decode && echo

# Log the argocd CLI in as platform-admin or dev
argocd-login user="platform-admin":
    @scripts/identities.sh login {{user}}

# Print the password of Kargo's admin account, which its UI signs in with
kargo-password:
    @kubectl --namespace kargo get secret kargo-admin-password --output jsonpath='{.data.password}' | base64 --decode && echo

# Print a token to log in to Headlamp (as its ServiceAccount, a cluster admin; valid for 24h)
headlamp-token:
    @kubectl --namespace headlamp create token headlamp --duration 24h

# Point the lab at your forks: replaces hvpaiva with your account in platform/ and in the workflows services call, and commits
use-fork owner:
    @scripts/use-fork.sh {{owner}}

# Render one of the platform's APIs against its example request, or one of its scenarios, and check it against the schemas
render api *flags: docker-ready
    @scripts/render.sh {{api}} {{flags}}

# Render a service through the platform's chart for every stage, the way CI validates it
render-service path="../back-hello/charts/hello":
    @scripts/render-service.sh {{path}}

# Check everything this repository defines, as CI does: scripts, health, apis, services and platform, or only the areas named
test *areas:
    @scripts/test.sh {{areas}}

# Show what this working copy would change in one Application, without applying it
diff app:
    @scripts/local.sh diff {{app}}

# Apply one Application from this working copy instead of from Git (pauses Argo CD for it)
local app:
    @scripts/local.sh apply {{app}}

# Put every Application back under Git
gitops:
    @scripts/local.sh gitops

# Undo the experiments: remove the requests nobody committed and put the lab back under Git
reset:
    @scripts/reset.sh

# Smoke-test the lab from the host
check:
    @scripts/check.sh

# Delete the cluster and everything in it
[confirm("Delete the 'back' kind cluster and everything in it? [y/N]")]
down: docker-ready
    @scripts/base.sh down
