# How it works

The lab has two kinds of users. A developer wants to ship a service without learning Kubernetes. The platform team wants every service to run the same safe way without reviewing each one.

A service asking for a database crosses all four tools. The dashed notes mark where one tool relies on another, which is where most of the platform's own configuration lives.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/request-flow-dark.svg">
  <img src="images/request-flow.svg" alt="A request for a database, in order: the developer asks Backstage, which opens a pull request on the service's staging branch; CI renders the chart and runs the platform's policies; after the merge Argo CD reads the branch and applies the Deployment and the Database, which Kyverno admits; Crossplane creates a CloudNativePG cluster, reads back the Secret it writes, and composes the service's own Secret with PG* keys; the new pods start once that Secret exists, Argo CD turns healthy when the Database is Ready, and Backstage shows all of it.">
</picture>

The diagram's source is `images/request-flow.excalidraw`.

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
database: {}
```

```yaml
# charts/hello/values-production.yaml: only what differs in production
image: ghcr.io/hvpaiva/back-hello:sha-4f96edd
size: medium
bucket:
  versioning: true
database:
  size: medium
```

`bucket:` asks the platform for an S3 bucket; the service gets its name and credentials as `BUCKET_NAME` and `AWS_*` environment variables. `database:` asks for a Postgres database; the service gets its address and credentials as `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` and `DATABASE_URL`, the variables any Postgres client already reads. hello's page shows whether it reaches each of them. Stages are branches: `staging` deploys to staging, `main` to production. The service's CI is two calls to workflows the platform provides in this repository: `service-go.yaml` checks a Go service (formatting, `go vet`, tests), and `service-delivery.yaml` does the rest, the same for every service.

Before any of that, a pull request gets checked: the delivery workflow renders `charts/hello/` with the platform's chart for each stage, so a typo or a size the platform doesn't offer fails in the pull request, with the chart's own message.

1. Push to `staging`. CI runs the tests, builds the image with the platform's Dockerfile for Go, tags it with the commit (`sha-<commit>`) and commits that image to `values-staging.yaml` on the same branch. In GitHub you see the workflow run and a commit from `github-actions[bot]`.
2. Argo CD notices the commit. It checks the repository every minute, so the `hello-staging` Application goes *OutOfSync*, then *Synced*, while the new pods roll out (*Progressing*) until they're ready (*Healthy*). The Argo CD UI shows each of those steps; Headlamp shows the pods themselves. If the lab has a GitHub App configured, GitHub shows the outcome too: the deployed commit gets an `argocd/hello-staging` status, and the version appears under the repository's Deployments.
3. The page updates itself. http://hello.staging.localhost reloads when the new version answers, and the hang tag's barcode changes with the version.
4. Promote with a pull request from `staging` to `main`. Merging it makes CI copy the image staging was running into `values-production.yaml`. Nothing is rebuilt, so production runs exactly what was tested.
5. Roll back by reverting the commit that changed the image. Argo CD puts the previous version back.

At no point does the developer (or CI) talk to the cluster. Git is the only interface, which is also why a new cluster rebuilt from the same repositories ends up running the same versions.

## Serving the developer (the platform's side)

The platform team owns this repository. Everything below can be changed from a working copy and seen before it's pushed: [things to try](experiments.md) walks that loop.

### The golden path

Every service is deployed by the same chart, `charts/app`, fed by the service's own values. Who decides what:

| The team declares | The platform decides |
|---|---|
| name and owning team | object names, labels, the namespace (`<name>-<stage>`) and the team's read access to it |
| the port it listens on | liveness and readiness probes on `/healthz` |
| a size: small, medium or large | replicas, CPU and memory for each size |
| whether it's public | the address: `<name>.<stage>.localhost`, `<name>.localhost` in production |
| a bucket, with or without versioning, and what to call it | its name in the cloud account, region and credentials, and that removing it never deletes the data |
| a database, small, medium or large, whether it starts from its backups, and what to call it | its address, how many instances run, the memory for each and the disk it starts with, its backups, and that removing it never deletes the data |
| | non-root user, read-only filesystem, no Kubernetes API token |

`values.schema.json` rejects any field the chart doesn't document, so a typo fails the sync with a message that names it, instead of being silently ignored. And because teams only describe intent, the platform can change how a service is deployed without touching a single service repository: hello is served through Traefik's Gateway in staging and through an Ingress in production, decided one stage at a time in the ApplicationSet, and hello's own values mention neither.

### The base layer

`cluster/` is what an infrastructure team would hand over: a cluster, an ingress controller and a cloud account, installed once by `just up`. Above it, only the bootstrap is applied by hand: Argo CD's first install, its projects and the root Application.

### Argo CD and what it delivers

`just up` installs Argo CD from its Helm chart and applies the projects and `platform/root.yaml`. That root Application delivers every manifest in `platform/apps/`, including an Application for Argo CD itself: from then on, upgrading Argo CD or adding a component to the platform is a commit. It delivers them in waves and waits for each to be healthy: the projects, then Argo CD, Headlamp, Crossplane, CloudNativePG, cert-manager and the cluster's RBAC, then the platform's APIs, plus CloudNativePG's backup plugin and Prometheus, whose certificates need cert-manager, then the ApplicationSet that creates the services, whose requests need those APIs. The same folder holds the AppProjects that separate the platform from the teams:

| Project | May read from | May deliver to | Cluster-wide objects |
|---|---|---|---|
| `platform` | this repository and approved Helm repositories | any namespace | any |
| `apps` | the services' repositories and the platform's chart | `*-staging` and `*-production` | only those namespaces |
| `default` | nothing | nowhere | none |

`default` is the project Argo CD creates for Applications that don't name one. It's closed, so every Application has to say which rules it follows.

### From service repositories to Applications

An ApplicationSet reads `charts/*/values.yaml` from each service's repository, once per stage branch, and creates one Application per service and stage (`hello-staging`, `hello-production`) in the `apps` project. Nobody writes those Applications by hand.

### The workflows services call

`.github/workflows/` holds reusable workflows, the GitHub Actions counterpart of CircleCI orbs. GitHub calls them from that folder only, which this repository's own CI shares, so the ones services call are named `service-*.yaml`. A service's CI is little more than two calls:

- `service-go.yaml` checks a Go service: formatting, `go vet` and the tests, with the Go version from its `go.mod`. Services in other languages would get their own.
- `service-delivery.yaml` takes the service's folder name and ships it, the same way for every service: validation on pull requests, build and deploy on `staging`, promotion on `main`. It builds the image with the platform's Dockerfile for the service's language, `build/go.Dockerfile` by default; a service with special needs can pass its own.

Services call them at `main`, so a fix reaches all of them at once.

### How the platform checks itself

`ci.yaml` checks this repository on every push to `main` and every pull request, with the command a platform engineer runs before pushing, `just test`, one job per area:

- `scripts`: the scripts behind the recipes and the workflows, through shellcheck and actionlint.
- `health`: the health checks Argo CD runs for the platform's kinds, asked about an object in each state they report.
- `apis`: every API rendered against its example request and against the scenarios in `tests/apis/`, which hand the Composition what a cluster would already hold.
- `services`: the chart rendered for the services in `tests/services/` and for the ones the ApplicationSet deploys, from the branches it reads them from, so a chart change that breaks a real service fails before it reaches that service.
- `platform`: every Application rendered the way Argo CD renders it, each chart with the values the lab gives it, and the base layer under them.

Everything rendered is checked against the schemas of the versions the lab pins. These jobs have no cluster, so what only an API server refuses is asked where there is one: by `just test` while the lab runs, and by `lab.yaml`, which builds the lab from nothing on a fresh machine, runs `just test` against it, asks the platform for one of everything it offers and resets it. It runs every night and after any push to `main` that changes more than docs, Dockerfiles or other workflows.

### Crossplane and the platform's APIs

`platform/apps/crossplane.yaml` installs Crossplane and, from `platform/crossplane/`, what the APIs build on: two functions for Compositions (go-templating and auto-ready), the AWS providers for S3, SQS and DynamoDB, and their connection to the cloud account. The S3 provider alone ships 50 resource types; Crossplane only serves the ones the platform uses, listed in an activation policy in `providers.yaml`. CloudNativePG, the operator databases are built on, comes from its own Application, `platform/apps/cloudnative-pg.yaml`, and its Barman Cloud plugin, which backs databases up, from `platform/apps/plugin-barman-cloud.yaml`.

`platform/apis/` holds the APIs services request resources through, all in `back.lab/v1alpha1` and all namespaced:

| Request | What the platform makes of it |
|---|---|
| `Bucket` | an S3 bucket, with versioning if asked for |
| `Database` | a Postgres cluster that CloudNativePG runs in the namespace: one instance for small, two for medium and three for large, with a disk sized when it's created, and backups in a `Bucket` of its own that a restore starts from |
| `Queue` | an SQS queue, plus a dead-letter queue where messages land after five failed deliveries |
| `Table` | a DynamoDB table with the keys asked for, billed per request |
| `Cache` | a Valkey server in the namespace, Redis-compatible, with a memory cap and a password of its own |

What a request makes is named after it. In the cloud account, which every namespace shares, a name starts with the namespace: hello's bucket in staging is `hello-staging-bucket`, and a `Table` called `visits` next to it is `hello-staging-visits`. In the namespace, a name is the request's name followed by its kind, or just the kind when that's what the request is called: a `Database` called `orders` has the Secret `orders-database`, and hello's, called `database`, has `database`. The chart names hello's requests after their kinds, and `name:` under `bucket:` or `database:` picks another. What a service reaches in the cluster has a name the platform gives it, never the name of what runs it: hello's database answers at `database.hello-staging.svc`, not at the Service CloudNativePG creates ([why](decisions.md#a-name-says-whose-a-thing-is-and-what-it-is-never-what-runs-it)).

Each one also composes the Secret the service reads its connection from. An API can request another one, too: a `Database` asks for a `Bucket` called `<name>-backups` and reads its Secret the way a service would. `Bucket` and `Database` are wired into the chart, with `bucket:` and `database:` in a service's values. A `Queue`, a `Table` or a `Cache` is requested by applying it to a namespace. `kubectl get buckets.back.lab -A` lists the requests, and `crossplane resource trace buckets.back.lab <name> -n <namespace>` shows what each one became. Always name a request with its group, as in `databases.back.lab`: CloudNativePG has a `Database` kind of its own. [When something doesn't work](troubleshooting.md) follows that chain to the end.

### Who can do what

Two identities stand for the two sides: `dev`, a developer in `team-a`, the team that owns hello, and `platform-admin`, in the `platform` team. In a company both would come from an identity provider. Here `just identities` gives each one a kubectl context and an Argo CD password. The context carries a certificate the cluster's CA signs through the CertificateSigningRequest API, naming the user and its group: what RBAC checks, as it would check an identity provider's token.

| | kubectl | Argo CD |
|---|---|---|
| `dev` (`team-a`) | reads its team's service namespaces: workloads, logs, events, requests and the resources Crossplane made for them; no Secrets, no changes | sees and syncs the services' Applications, and reads their logs |
| `platform-admin` (`platform`) | everything | everything |

The `developer` role, in `platform/rbac/`, combines Kubernetes' `view` role with Crossplane's read access to requests and managed resources. `charts/app` grants it to the service's team in every namespace it deploys to, so a new service's team can read it from the start. `crossplane resource trace` works for a developer too, down to the Secret it can't read. Argo CD's built-in `admin` account is off; the kind cluster's own admin (`kubectl --context kind-back`) is what `just` builds the cluster with.

[Look at it as a developer](experiments.md#look-at-it-as-a-developer) tries it.
