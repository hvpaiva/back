# When something doesn't work

Almost everything that breaks here breaks at a handoff between two tools, and each handoff has a
place where it says why. This is the order to walk them, and the commands are the same ones the
platform team would run in a real cluster.

| What you see | Start at |
|---|---|
| A change was pushed and nothing happened | [the Application](#the-application) |
| *Synced*, but the service still runs the old version | [the Application](#the-application), then [the service](#the-service) |
| A request stays *Progressing* and never turns ready | [the request](#the-request) |
| The service starts but can't reach what it asked for | [the request](#the-request), then [LocalStack](#localstack) |
| The page doesn't answer at all | [the service](#the-service) |
| `just up` stops at `kind create cluster` | [the cluster](#the-cluster-wont-come-up) |

Run everything from this directory: `mise.toml` points kubectl, the argocd CLI and the AWS CLI at
the lab.

A step of `just up` that fails prints what the tool said, right there. Every run also appends it to
`.logs/lab.log`, with the command and the time, which is where to read the run before this one.

## The cluster won't come up

`kind create cluster` fails when something else holds port 80, 443 or 4566, usually another cluster
or a container from another project. Docker names it without sudo:

```sh
docker ps --filter publish=80
```

`ss -ltnp` shows only `docker-proxy` for those ports, and needs sudo to show that much. Deleting
another kind cluster has a catch: do it from outside this directory, or `KUBECONFIG` points at the
lab's own file and the other cluster's context stays behind in `~/.kube/config`.

## The Application

```sh
argocd app get hello-staging              # or: just argocd-login platform-admin, first
argocd app get hello-staging --refresh    # check the repository now, instead of within a minute
```

Sync status and health answer different questions. *Synced* means the cluster holds what Git says,
and *Healthy* means what it holds is working. A service that deploys a broken image is Synced and
Degraded; a service whose last commit never arrived is OutOfSync and Healthy.

An Application's health only counts its own resources, so a request that Crossplane can't fulfil
doesn't make the service's Application unhealthy on its own. The platform adds a health check for
its own kinds, and the tree in the UI shows it.

Two things are worth knowing before hunting further: Argo CD polls every minute here, and it
answers `permission denied` for an Application that doesn't exist. Both are in
[platform notes](platform-notes.md).

## The request

A request becomes managed resources, and each of those talks to something outside the cluster.

```sh
crossplane resource trace buckets.back.lab hello -n hello-staging
```

The tree shows both conditions for every level. `SYNCED` means Crossplane reconciled the resource
without an error; `READY` means whatever is on the other side reports it exists. Synced but not
Ready is normal for a few seconds after a request, and permanent when the other side is refusing
something.

The message is on the managed resource, not on the request:

```sh
kubectl -n hello-staging describe buckets.s3.aws.m.upbound.io   # conditions and events
kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-aws-s3 --tail=30
```

If the request produced nothing at all, the Composition itself failed. Crossplane records that on
the request (`kubectl -n hello-staging describe buckets.back.lab hello`), and `just render bucket`
reproduces it on your machine, without the cluster.

## LocalStack

The provider's view and LocalStack's view can disagree, and LocalStack keeps its state in memory:
restart it and every bucket, queue and table is gone, while Crossplane still believes they exist.
It notices within a minute and creates them again.

```sh
aws s3 ls
aws sqs list-queues
aws dynamodb list-tables
curl -s localhost:4566/_localstack/health | jq
```

## The service

```sh
kubectl -n hello-staging get pods
kubectl -n hello-staging logs deploy/hello
kubectl -n hello-staging get events --sort-by=.lastTimestamp | tail
```

A pod stuck in `ContainerCreating` is usually waiting for a Secret it mounts: the request that
composes it isn't ready yet, and the pod starts on its own once it is. `ImagePullBackOff` on a
fork means the package GitHub created is private.

The route is separate from the pod. If the pod is Running and the address doesn't answer, check
that the service asked to be public (`public: true` in its values) and that the Ingress got an
address: `kubectl -n hello-staging get ingress`.

## Starting over

Deleting a request deletes what it created, and the platform's requests hold data, so Argo CD never
prunes them on its own. Deleting one by hand is the explicit operation:

```sh
kubectl -n hello-staging delete buckets.back.lab hello
```

Delete requests before their namespace: a namespace deleted with managed resources still in it gets
stuck, and so do they ([platform notes](platform-notes.md)).

`just down && just up` rebuilds everything from scratch in a few minutes, and the services come back
at the versions Git says they run.
