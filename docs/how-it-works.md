# How it works

The lab has two kinds of users. A developer wants to ship a service without learning Kubernetes. The platform team wants every service to run the same safe way without reviewing each one.

## Shipping a change (the developer's side)

The service's repository has everything the developer touches: code, tests, a CI workflow, and a `charts/<service>/` folder that says what the service needs.

```yaml
# charts/hello/values.yaml: every stage
application:
  name: hello
  team: team-a
port: 8080
size: small
public: true
bucket: {}
```

```yaml
# charts/hello/values-production.yaml: only what differs in production
image: ghcr.io/hvpaiva/back-hello:sha-4f96edd
size: medium
bucket:
  versioning: true
```

`bucket:` asks the platform for an S3 bucket; the service gets its name and credentials as `BUCKET_NAME` and `AWS_*` environment variables, and hello's page shows whether it reaches it. Stages are branches: `staging` deploys to staging, `main` to production. The service's CI is two calls to workflows the platform provides in this repository: `go.yaml` checks a Go service (formatting, `go vet`, tests), and `delivery.yaml` does the rest, the same for every service.

Before any of that, a pull request gets checked: the delivery workflow renders `charts/hello/` with the platform's chart for each stage, so a typo or a size the platform doesn't offer fails in the pull request, with the chart's own message.

1. Push to `staging`. CI runs the tests, builds the image with the platform's Dockerfile for Go, tags it with the commit (`sha-<commit>`) and commits that image to `values-staging.yaml` on the same branch. In GitHub you see the workflow run and a commit from `github-actions[bot]`.
2. Argo CD notices the commit. It checks the repository every minute, so the `hello-staging` Application goes *OutOfSync*, then *Synced*, while the new pods roll out (*Progressing*) until they're ready (*Healthy*). The Argo CD UI shows each of those steps; Headlamp shows the pods themselves. If the lab has a GitHub App configured, GitHub shows the outcome too: the deployed commit gets an `argocd/hello-staging` status, and the version appears under the repository's Deployments.
3. The page updates itself. http://hello.staging.localhost reloads when the new version answers, and the hang tag's barcode changes with the version.
4. Promote with a pull request from `staging` to `main`. Merging it makes CI copy the image staging was running into `values-production.yaml`. Nothing is rebuilt, so production runs exactly what was tested.
5. Roll back by reverting the commit that changed the image. Argo CD puts the previous version back.

At no point does the developer (or CI) talk to the cluster. Git is the only interface, which is also why a new cluster rebuilt from the same repositories ends up running the same versions.

## Serving the developer (the platform's side)

The platform team owns this repository. Everything below can be changed from a working copy and
seen before it's pushed: [things to try](experiments.md) walks that loop.

### The base layer

`cluster/` is what an infrastructure team would hand over: a cluster, an ingress controller and a cloud account, installed once by `just up`. Above it, only the bootstrap is applied by hand: Argo CD's first install, its projects and the root Application.

### Argo CD and what it delivers

`just up` installs Argo CD with Helm and applies the projects and `platform/root.yaml`. That root Application delivers every manifest in `platform/apps/`, including an Application for Argo CD itself: from then on, upgrading Argo CD or adding a component to the platform is a commit. It delivers them in waves and waits for each to be healthy: the projects, then Argo CD, Headlamp, Crossplane, CloudNativePG and the cluster's RBAC, then the platform's APIs, then the ApplicationSet that creates the services, whose requests need those APIs. The same folder holds the AppProjects that separate the platform from the teams:

| Project | May read from | May deliver to | Cluster-wide objects |
|---|---|---|---|
| `platform` | this repository and approved Helm repositories | any namespace | any |
| `apps` | the services' repositories and the platform's chart | `*-staging` and `*-production` | only those namespaces |
| `default` | nothing | nowhere | none |

`default` is the project Argo CD creates for Applications that don't name one. It's closed, so every Application has to say which rules it follows.

### From service repositories to Applications

An ApplicationSet reads `charts/*/values.yaml` from each service's repository, once per stage branch, and creates one Application per service and stage (`hello-staging`, `hello-production`) in the `apps` project. Nobody writes those Applications by hand.

### The workflows services call

`.github/workflows/` holds reusable workflows, the GitHub Actions counterpart of CircleCI orbs. A service's CI is little more than two calls:

- `go.yaml` checks a Go service: formatting, `go vet` and the tests, with the Go version from its `go.mod`. Services in other languages would get their own.
- `delivery.yaml` takes the service's folder name and ships it, the same way for every service: validation on pull requests, build and deploy on `staging`, promotion on `main`. It builds the image with the platform's Dockerfile for the service's language, `build/go.Dockerfile` by default; a service with special needs can pass its own.

Services call them at `main`, so a fix reaches all of them at once.

### Crossplane and the platform's APIs

`platform/apps/crossplane.yaml` installs Crossplane and, from `platform/crossplane/`, what the APIs build on: two functions for Compositions (go-templating and auto-ready), the AWS providers for S3, SQS and DynamoDB, and their connection to LocalStack. The S3 provider alone ships 50 resource types; Crossplane only serves the ones the platform uses, listed in an activation policy in `providers.yaml`.

`platform/apis/` holds the APIs services request resources through, all in `back.lab/v1alpha1` and all namespaced:

| Request | What the platform makes of it |
|---|---|
| `Bucket` | an S3 bucket named `<namespace>-<name>`, with versioning if asked for |
| `Queue` | an SQS queue, plus a dead-letter queue where messages land after five failed deliveries |
| `Table` | a DynamoDB table with the keys asked for, billed per request |
| `Cache` | a Valkey server in the namespace, Redis-compatible, with a memory cap and a password of its own |

Each one also composes the Secret the service reads its connection from: `<name>-bucket`, `<name>-queue`, `<name>-table`, `<name>-cache`. Only `Bucket` is wired into the chart so far, with `bucket:` in a service's values; the others are requested by applying a `Queue`, a `Table` or a `Cache` to a namespace. `kubectl get buckets.back.lab -A` lists the requests; `crossplane resource trace buckets.back.lab <name> -n <namespace>` shows what each one became, and [when something doesn't work](troubleshooting.md) follows that chain to the end.

### Who can do what

Two identities stand for the two sides: `dev`, a developer in `team-a`, the team that owns hello, and `platform-admin`, in the `platform` team. In a company both would come from an identity provider. Here `just identities` gives each one a kubectl context and an Argo CD password. The context carries a certificate the cluster's CA signs through the CertificateSigningRequest API, naming the user and its group: what RBAC checks, as it would check an identity provider's token.

| | kubectl | Argo CD |
|---|---|---|
| `dev` (`team-a`) | reads its team's service namespaces: workloads, logs, events, requests and the resources Crossplane made for them; no Secrets, no changes | sees and syncs the services' Applications, and reads their logs |
| `platform-admin` (`platform`) | everything | everything |

The `developer` role, in `platform/rbac/`, combines Kubernetes' `view` role with Crossplane's read access to requests and managed resources. `charts/app` grants it to the service's team in every namespace it deploys to, so a new service's team can read it from the start. `crossplane resource trace` works for a developer too, down to the Secret it can't read. Argo CD's built-in `admin` account is off; the kind cluster's own admin (`kubectl --context kind-back`) is what `just` builds the cluster with.

Try `kubectl --context dev -n hello-staging get pods,buckets.back.lab`, then `kubectl --context dev get compositions`.

### The golden path

Every service is deployed by the same chart, `charts/app`, fed by the service's own values. Who decides what:

| The team declares | The platform decides |
|---|---|
| name and owning team | object names, labels, the namespace (`<name>-<stage>`) and the team's read access to it |
| the port it listens on | liveness and readiness probes on `/healthz` |
| a size: small, medium or large | replicas, CPU and memory for each size |
| whether it's public | the address: `<name>.<stage>.localhost`, `<name>.localhost` in production |
| a bucket, with or without versioning | its name, region and credentials, and that removing it never deletes the data |
| | non-root user, read-only filesystem, no Kubernetes API token |

`values.schema.json` rejects any field the chart doesn't document, so a typo fails the sync with a message that names it, instead of being silently ignored. And because teams only describe intent, the platform can change how a service is deployed (say, routes through Gateway API instead of Ingress) by changing the chart, without touching a single service repository.
