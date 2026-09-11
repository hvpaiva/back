# BACK lab

A local, self-contained lab for the BACK stack (Backstage, Argo CD, Crossplane and Kyverno), built to understand how the four tools connect: from a developer asking for a new service to the resources that end up running.

Everything runs on one machine, in a single kind cluster, with LocalStack standing in for AWS. No company clusters, cloud accounts or repositories are involved.

## Quick start

Tested on Ubuntu 24.04, where `setup.sh` also installs what's missing. On other systems it runs the same checks and tells you what to install.

```sh
./setup.sh   # check this machine and offer to install what's missing
just up      # create the cluster and the base layer (idempotent, ~1 min)
just         # list every recipe
just down    # delete the cluster
```

`setup.sh` checks curl, git, Docker, free ports (80, 443, 4566), RAM, disk, [mise](https://mise.jdx.dev) and the toolchain pinned in `mise.toml`. For anything missing it offers a fix: on Ubuntu, curl and git through apt and Docker Engine through Docker's apt repository; anywhere, mise through its official installer, the pinned toolchain, and a line in your shell rc that activates mise. Every change asks first. `./setup.sh --check` only checks, and `just up` runs it before doing anything.

If mise isn't active in your shell, prefix commands with `mise exec --`, as in `mise exec -- just up`.

The base layer uses about 1 GB of RAM and 4 GB of disk.

## What's running

| Component | Role | Reach it at |
|---|---|---|
| kind, Kubernetes 1.35 | The single-node cluster the whole lab lives in | `kubectl`, from this directory |
| Traefik 3.7 | Entry point, serving both Ingress and Gateway API | `http://<name>.localhost`; dashboard at http://traefik.localhost/dashboard/ |
| LocalStack 4.14.0 | Stands in for AWS (S3, SQS, DynamoDB, …) | `http://localhost:4566` from the host; `http://localstack.localstack.svc:4566` from pods |

To expose something, point an `Ingress` (class `traefik`, the default) or an `HTTPRoute` (parent: Gateway `traefik-gateway` in namespace `traefik`) at a hostname ending in `.localhost`.

## Isolation

Inside this directory, `mise.toml` sets:

- `KUBECONFIG` to `.kube/config` (git-ignored), so `kubectl` and `helm` can only reach the lab cluster.
- `AWS_ENDPOINT_URL` and dummy credentials, so every AWS call goes to LocalStack even if real AWS profiles are configured.

The justfile exports the same `KUBECONFIG`, so its recipes only ever touch the lab cluster. Host ports are bound to `127.0.0.1` only.

`*.localhost` resolves to this machine only on the host. Inside the cluster, use Service DNS names (`<service>.<namespace>.svc`).

## Layout

`cluster/` holds the base layer: what an infrastructure team would hand us (a cluster, an ingress, a cloud account). It's installed by `just`, not by GitOps. From phase 1 on, everything above the base layer is declared in Git and delivered by Argo CD.

## Decisions

- **A single kind node.** Enough for the whole lab, and the lightest option.
- **Kubernetes 1.35 instead of kind's default 1.37.** Argo CD, Crossplane and Kyverno have had months to support it.
- **Traefik.** It serves Ingress and Gateway API at the same time, so a platform abstraction can move from one to the other without changes to the cluster. ingress-nginx reached end of life in March 2026.
- **Gateway API CRDs v1.6.1, installed before Traefik.** It's the version Traefik 3.7 is built against.
- **LocalStack 4.14.0, pinned by digest.** The Community edition ended on 2026-03-23. Newer images require an account and an auth token, and the free plan covers non-commercial use only. 4.14.0 is the last Community release: it runs without a token but gets no updates or security patches, and it never included RDS. State is kept in memory, so restarting the pod wipes it.
- **just.** Readable recipes, pinned by mise like the rest of the toolchain.
- **`setup.sh` in plain bash.** It has to work before mise and just exist.
- **Public repositories on a personal GitHub account.** Nothing touches company organizations.

## Roadmap

| Phase | Outcome | Status |
|---|---|---|
| 0. Base layer | `just up` creates the cluster, the gateway and LocalStack | Done |
| 1. GitOps first | Argo CD manages itself and the platform; sample app via ApplicationSet; CI builds the image and bumps the tag in Git; promotion between environments via PR | Next |
| 2. Crossplane | `Bucket`, `Database` and `App` platform APIs, delivered by Argo CD | |
| 3. Evolving the platform | Composition revisions (Ingress → Gateway API), a second implementation behind the same API, adopting Terraform-managed resources, drift correction | |
| 4. Kyverno | CEL policies on the platform APIs, audit → enforce, team onboarding via generate rules, policy checks in CI | |
| 5. Backstage | "New service" template (repo + PR), catalog with Kubernetes, Argo CD, Crossplane and Kyverno plugins | |
| 6. Demo | Script, pre-baked states, backup recording | |
