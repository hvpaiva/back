# How it works

The lab has two kinds of users. A developer wants to ship a service without learning Kubernetes. The platform team wants every service to run the same safe way without reviewing each one.

## Shipping a change (the developer's side)

The service's repository has everything the developer touches: code, tests, a Dockerfile, a CI workflow, and a `charts/<service>/` folder that says what the service needs.

```yaml
# charts/hello/values.yaml: every stage
application:
  name: hello
  team: platform
port: 8080
size: small
public: true
```

```yaml
# charts/hello/values-production.yaml: only what differs in production
image: ghcr.io/hvpaiva/back-hello:sha-4f96edd
size: medium
```

Stages are branches: `staging` deploys to staging, `main` to production.

1. Push to `staging`. CI runs the tests, builds the image, tags it with the commit (`sha-<commit>`) and commits that image to `values-staging.yaml` on the same branch. In GitHub you see the workflow run and a commit from `github-actions[bot]`.
2. Argo CD notices the commit. It checks the repository every minute, so the `hello-staging` Application goes *OutOfSync*, then *Synced*, while the new pods roll out (*Progressing*) until they're ready (*Healthy*). The Argo CD UI shows each of those steps; Headlamp shows the pods themselves.
3. The page updates itself. http://hello.staging.localhost reloads when the new version answers, and the hang tag's barcode changes with the version.
4. Promote with a pull request from `staging` to `main`. Merging it makes CI copy the image staging was running into `values-production.yaml`. Nothing is rebuilt, so production runs exactly what was tested.
5. Roll back by reverting the commit that changed the image. Argo CD puts the previous version back.

At no point does the developer (or CI) talk to the cluster. Git is the only interface, which is also why a new cluster rebuilt from the same repositories ends up running the same versions.

## Serving the developer (the platform's side)

The platform team owns this repository.

### The base layer

`cluster/` is what an infrastructure team would hand over: a cluster, an ingress controller and a cloud account, installed once by `just up`. Nothing above it is installed by hand except one file.

### Argo CD and what it delivers

`just up` installs Argo CD with Helm and applies `platform/root.yaml`. That root Application delivers every manifest in `platform/apps/`, including an Application for Argo CD itself: from then on, upgrading Argo CD or adding a component to the platform is a commit. The same folder holds the AppProjects that separate the platform from the teams:

| Project | May read from | May deliver to | Cluster-wide objects |
|---|---|---|---|
| `platform` | this repository and approved Helm repositories | any namespace | any |
| `apps` | the services' repositories and the platform's chart | `*-staging` and `*-production` | only those namespaces |

### From service repositories to Applications

An ApplicationSet reads `charts/*/values.yaml` from each service's repository, once per stage branch, and creates one Application per service and stage (`hello-staging`, `hello-production`) in the `apps` project. Nobody writes those Applications by hand.

### The golden path

Every service is deployed by the same chart, `charts/app`, fed by the service's own values. Who decides what:

| The team declares | The platform decides |
|---|---|
| name and owning team | object names, labels, namespace (`<name>-<stage>`) |
| the port it listens on | liveness and readiness probes on `/healthz` |
| a size: small, medium or large | replicas, CPU and memory for each size |
| whether it's public | the address: `<name>.<stage>.localhost`, `<name>.localhost` in production |
| | non-root user, read-only filesystem, no Kubernetes API token |

`values.schema.json` rejects any field the chart doesn't document, so a typo fails the sync with a message that names it, instead of being silently ignored. And because teams only describe intent, the platform can change how a service is deployed (say, routes through Gateway API instead of Ingress) by changing the chart, without touching a single service repository.
