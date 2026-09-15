# When something doesn't work

Almost everything that breaks here breaks at a handoff between two tools, and each handoff has a place where it says why. This is the order to walk them, and the commands are the same ones the platform team would run in a real cluster.

| What you see | Start at |
|---|---|
| A change was pushed and nothing happened | [the Application](#the-application) |
| *Synced*, but the service still runs the old version | [the Application](#the-application), then [the service](#the-service) |
| A request stays *Progressing* and never turns ready | [the request](#the-request) |
| A request's kind doesn't exist right after its API was applied | [the request](#the-request) |
| A database's INSTANCES stays below what its size asks for | [the request](#the-request) |
| A database isn't ready: its archiving fails, or its restore never finishes | [the request](#the-request) |
| The service starts but can't reach what it asked for | [the request](#the-request), then [the cloud account](#the-cloud-account) |
| The page doesn't answer at all | [the service](#the-service) |
| The Application reads *Suspended* for a minute after a push | [the service](#the-service) |
| `just up` stops at `kind create cluster` | [the cluster](#the-cluster-wont-come-up) |
| A check fails on GitHub | [CI](#ci) |

Run everything from this directory: `mise.toml` points kubectl, the argocd CLI and the AWS CLI at the lab.

A step of `just up` that fails prints what the tool said, right there. Every run also appends it to `.logs/lab.log`, with the command and the time, which is where to read the run before this one.

## The cluster won't come up

`kind create cluster` fails when something else holds port 80, 443 or 4566, usually another cluster or a container from another project. Docker names it without sudo:

```sh
docker ps --filter publish=80
```

`ss -ltnp` shows only `docker-proxy` for those ports, and needs sudo to show that much. Deleting another kind cluster has a catch: do it from outside this directory, or `KUBECONFIG` points at the lab's own file and the other cluster's context stays behind in `~/.kube/config`.

## The Application

```sh
argocd app get hello-staging              # or: just argocd-login platform-admin, first
argocd app get hello-staging --refresh    # check the repository now, instead of within a minute
```

Sync status and health answer different questions. *Synced* means the cluster holds what Git says, and *Healthy* means what it holds is working. A service that deploys a broken image is Synced and Degraded; a service whose last commit never arrived is OutOfSync and Healthy.

An Application's health only counts its own resources, and the managed resources a request creates aren't among them: what happens to them reaches the Application through the request or not at all. The platform adds a health check for its own kinds, which reads a request that isn't ready as *Progressing* and one Crossplane can't process as *Degraded*, and the tree in the UI shows which level it came from ([more](platform-notes.md#argo-cd-cant-judge-the-platforms-own-kinds)).

Two things are worth knowing before hunting further: Argo CD [polls every minute](platform-notes.md#a-local-cluster-gets-no-webhooks) here, and it [answers `permission denied`](platform-notes.md#permission-denied-can-mean-doesnt-exist) for an Application that doesn't exist.

## The request

A request becomes managed resources, and each of those talks to something outside the cluster.

```sh
crossplane resource trace buckets.back.lab bucket -n hello-staging
```

The tree shows both conditions for every level. `SYNCED` means Crossplane reconciled the resource without an error; `READY` means whatever is on the other side reports it exists. Synced but not Ready is normal for a few seconds after a request, and permanent when the other side is refusing something.

The message is on the managed resource, not on the request:

```sh
kubectl -n hello-staging describe buckets.s3.aws.m.upbound.io   # conditions and events
kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-aws-s3 --tail=30
```

If the request produced nothing at all, the Composition itself failed. Crossplane records that on the request (`kubectl -n hello-staging describe buckets.back.lab bucket`), and `just render bucket` reproduces it on your machine, without the cluster.

A request whose kind doesn't exist (`no matches for kind`) after its API was applied usually has an XRD the API server refused to turn into a CRD. `kubectl get xrd` lists that XRD without ESTABLISHED, and only an event on it says why: `kubectl describe xrd databases.back.lab`. `just render database` shows the same refusal before anything reaches the cluster ([more](platform-notes.md#an-xrd-the-api-server-refuses-shows-no-error)).

A `Database` composes no managed resources. It composes a CloudNativePG cluster, and the cluster has a status of its own:

```sh
kubectl -n hello-staging get databases.back.lab database          # INSTANCES: ready out of what the size asks for
kubectl -n hello-staging get clusters.postgresql.cnpg.io database
kubectl -n cnpg-system logs deploy/cloudnative-pg --tail=30
```

An INSTANCES count that stays below its total means the cluster stopped short, even when the request and the cluster both read as ready, and the operator's log says where ([one way that happens](platform-notes.md#a-database-that-cant-grow-its-disk-still-reads-healthy)).

A database's backups show on its request as well: LAST BACKUP in that same line, and in its YAML `restorableFrom`, the earliest moment a restore can go back to. A database whose status says `archiving: failing` isn't ready, and the plugin's container says why:

```sh
kubectl -n hello-staging logs database-1 -c plugin-barman-cloud | grep -i error
```

`Expected empty archive` means the database started empty where an earlier one left its backups, which is what happens when Argo CD brings back the request of a database that was deleted. Restore it, or remove those backups from its bucket if nobody wants them ([why it refuses](platform-notes.md#a-database-cant-archive-into-backups-that-arent-its-own)). A restore that never finishes shows as a job, `database-1-full-recovery` for hello's database, whose pods keep failing, and its log names what Postgres refused. `requested timeline 3 is not a child of this server's history` has a way out ([more](platform-notes.md#a-restore-can-start-from-a-timeline-another-restore-left-behind)).

## The cloud account

The provider's view and the emulator's view can disagree, and the emulator keeps its state in memory: restart it and every bucket, queue and table is gone, databases' backups included, while Crossplane still believes they exist. Crossplane notices within a minute and creates them again ([why this emulator](decisions.md#ministack-as-the-cloud-account-pinned-by-digest)). A database goes on archiving into its new, empty bucket, but has no full backup to restore from until the next night: within five minutes its status stops naming the lost one, and `just check` says the database was never backed up. Deleting its backup schedule takes a full backup straight away, since the platform composes the schedule again at once:

```sh
kubectl -n hello-staging delete scheduledbackups.postgresql.cnpg.io database-backups
```

```sh
aws s3 ls
aws sqs list-queues
aws dynamodb list-tables
curl -s localhost:4566/health | jq
```

## The service

```sh
kubectl -n hello-staging get pods
kubectl -n hello-staging logs -l app.kubernetes.io/name=hello
kubectl -n hello-staging get events --sort-by=.lastTimestamp | tail
```

A service runs as a Rollout, which `kubectl logs` can't take by name, hence the label. For about a minute after a new version, its Application reads *Suspended* while the canary waits between steps; http://rollouts.localhost shows which step it's on and how the requests are split.

A pod in `CreateContainerConfigError` is missing a Secret it reads its environment from, and `kubectl describe pod` names that Secret (`secret "bucket" not found`). The request that composes the Secret either doesn't exist or hasn't composed it yet, and the pod starts on its own once the Secret is there. `ImagePullBackOff` on a fork means the package GitHub created is private.

A database's Secret arrives before the database does. It exists about a second after the request, because CloudNativePG writes the credentials as soon as it creates the cluster, and Postgres took about 20 more seconds to accept connections. A service that tries its database only once, at startup, can miss that window. hello pings on every request, so its page says unreachable until the database answers.

The route is separate from the pod. If the pod is Running and the address doesn't answer, check that the service asked to be public (`public: true` in its values) and that whichever front door serves that stage is there: `kubectl -n hello-staging get ingress,httproute`. Which front door a stage uses comes from the ApplicationSet, not from the service.

## CI

Each of `ci.yaml`'s checks runs an area of `just test`, and is named after it, so `just test apis` reproduces the `apis` check here, line for line. With the lab running, the same command also asks the API server, which CI's checks can't. `lab.yaml` builds the lab from nothing with the recipes a first run uses; when a step fails, the last one prints the Applications, what Crossplane holds, the pods that aren't running and the end of `.logs/lab.log`.

## Starting over

The platform's requests hold data, so nothing deletes it on its own. A bucket or a table outlives its request, and applying the same request again picks its data back up ([why](decisions.md#a-services-data-outlives-its-request)). Removing the data is a second, explicit step, in the account:

```sh
kubectl -n hello-staging delete tables.back.lab visits
aws dynamodb delete-table --table-name hello-staging-visits
```

`just reset` takes both steps for every request nobody committed. A request Git holds comes back on Argo CD's next sync and adopts what it had.

A database's request is refused while the Usage next to it exists. Deleting a database on purpose starts with that Usage (`kubectl -n hello-staging delete usages.protection.crossplane.io database`), and the database's volumes go with its request, while its backups stay in its bucket. For a request Git holds, Argo CD then puts both back on its next sync, with an empty database that refuses to archive over those backups until it's restored or they're removed. With `restore: {}` under `database:` in the service's values beforehand, it comes back with its data instead ([try it](experiments.md#lose-a-database-and-get-it-back)). `just reset` deletes the Usages nobody committed before the requests they protect, and the backups of the databases it deletes.

Delete requests before their namespace: a namespace deleted with managed resources still in it can get stuck, and so can they ([platform notes](platform-notes.md#deleting-a-namespace-can-strand-its-managed-resources)).

`just down && just up` rebuilds everything from scratch in a few minutes, and the services come back at the versions Git says they run.
