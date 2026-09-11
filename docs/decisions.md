# Decisions

Why the lab is built the way it is. Most of these trade realism for something that runs on one laptop.

## Cluster and base layer

- One kind node. Enough for the whole lab, and the lightest option.
- Kubernetes 1.35, not kind's default 1.37. A release Argo CD, Crossplane and Kyverno have had months to support.
- Traefik as the ingress controller. It serves Ingress and Gateway API at the same time, so the platform can move services from one to the other without touching the cluster. ingress-nginx, the usual choice, reached end of life in March 2026.
- Gateway API CRDs v1.6.1, installed before Traefik. The version Traefik 3.7 is built against; its chart doesn't ship them.
- LocalStack 4.14.0, pinned by digest. The Community edition ended in March 2026: newer images need an account and an auth token, and the free plan is for non-commercial use only. 4.14.0 is the last Community release. It runs without a token, but it gets no updates or security patches, and it never included RDS. Its state lives in memory.
- Base layer installed by `just`, everything else by Argo CD. The base layer stands for what an infrastructure team provides. Everything a platform team would own is in Git.

## Delivery

- Argo CD installed once, then managing itself. The first install is the only step that isn't GitOps.
- Deploy configuration lives in the service's repository, one branch per stage. It keeps what a service needs next to its code, and it's the model teams are likely to meet in practice. The alternative, a separate repository with a folder per environment, makes promotion a one-line change in one place, at the cost of a second repository for every change.
- The running version is in Git. CI commits the image it built instead of telling Argo CD about it through its API. Git then always says what runs where, rollback is a revert, a rebuilt cluster comes back with the same versions, and CI needs no access to the cluster. The cost is a commit from CI on every deploy.
- Production runs the image staging ran. Promotion copies the image; it doesn't rebuild from `main`.
- Deploy feedback comes from Argo CD, not from CI. CI is done once it commits the image; Argo CD tells GitHub when that version is running and healthy, through a GitHub App, so CI still needs no access to the cluster.
- The platform maintains the services' CI too: checks per language (`go.yaml` for now) and one delivery workflow for all. Services call them at `main`, the same trade-off as the chart: a fix reaches every service at once, and so does a mistake. A service that needs stability can pin a commit instead.
- A Helm chart as the golden path. Helm is how many teams already package their services. Here the platform maintains one chart, and each service only declares what it needs, much like a CircleCI orb.
- Services in public GitHub repositories on a personal account. Argo CD reads them without credentials, and no company system is involved.

## Crossplane

- Crossplane v2, with namespaced managed resources. What a service requests, and what that creates, lives in the service's namespace.
- AWS providers built by crossplane-contrib. Upbound publishes the same providers, but only their latest version is free; contrib's builds are Apache 2.0 and every version stays available.
- Only the resource types the platform uses are activated. The S3 provider alone ships 50, and each active one is a CRD the API server and Argo CD keep track of. With so few, the lab doesn't need the higher Argo CD API rate limit that Crossplane's Argo CD guide recommends.
- Every package pinned in Git, dependencies included. The family provider is declared rather than left to Crossplane's dependency resolution, which would install whatever version it finds.
- Compositions in Go templates (function-go-templating). They read like the Helm templates of the platform's chart.

## Tooling

- just. Readable recipes, pinned by mise like the rest of the toolchain.
- `setup.sh` in plain bash. It has to work before mise and just exist.
