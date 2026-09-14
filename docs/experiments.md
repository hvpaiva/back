# Things to try

The lab is put together to be changed, not only read, and each of these says what to run and what you should see. The three groups differ in what they need: a running lab, a working copy of this repository, or your own forks. Everything runs from this directory, where `mise.toml` points the tools at the lab.

| Try | What it shows | Needs |
|---|---|---|
| [Ask the platform for something](#ask-the-platform-for-something) | A request becomes cloud resources and a Secret, and the trace shows each step | A running lab |
| [Delete a request, keep its data](#delete-a-request-keep-its-data) | Data outlives the request that created it | A running lab |
| [Change what a service was given](#change-what-a-service-was-given) | A changed Secret rolls the pods that read it | A running lab |
| [Look at it as a developer](#look-at-it-as-a-developer) | A developer reads the cluster and changes it only through Git | A running lab |
| [Watch Git win](#watch-git-win) | Argo CD undoes a change made in the cluster | A running lab |
| [Break it on purpose](#break-it-on-purpose) | How an outage in the cloud account travels up to the Application | A running lab |
| [Change what a request is made of](#change-what-a-request-is-made-of) | The contract survives swapping what fulfills it | A working copy |
| [Move a service to the other front door](#move-a-service-to-the-other-front-door) | The platform migrates a service without touching its repository | A working copy |
| [Add a field to an API](#add-a-field-to-an-api) | How an API grows, and how it refuses a change | A working copy |
| [Resize a service and watch it promote](#resize-a-service-and-watch-it-promote) | The developer's loop, from a push to production | Your forks |
| [Change the golden path for every service at once](#change-the-golden-path-for-every-service-at-once) | One chart change reaches every service | Your forks |

When one of them leaves something behind, `just reset` takes out the requests nobody committed, with the buckets and tables they leave in the cloud account, and puts every Application back under Git, without rebuilding the lab. It leaves your edits alone: `git status` says which files you changed, and `git checkout` on them drops the changes.

## Using the platform

### Ask the platform for something

Every API ships an example request next to its Composition:

```sh
kubectl apply -f platform/apis/queue/example.yaml
crossplane resource trace queues.back.lab emails -n hello-staging
kubectl -n hello-staging get secret emails-queue -o jsonpath='{.data.QUEUE_URL}' | base64 -d
```

In a few seconds the request is ready, two queues exist in the cloud account (`aws sqs list-queues`: the queue and the dead-letter queue messages land in after five failed deliveries) and the Secret holds what a service would read. `kubectl -n hello-staging delete queues.back.lab emails` takes all of it back.

The trace names both queues, `emails` and `emails-dlq`, and the Secret only appears once both have a URL: the first trace shows the tree without it, and the dead-letter rule lands one reconcile later, when the queue has an ARN to point at. Argo CD shows none of this, since nothing in Git asked for the request and no project here tracks resources nobody asked for. Headlamp lists it with the cluster's other custom resources.

No service uses that one. `Bucket` is the only request the chart renders today, from `bucket:` in a service's values; the others exist so the platform offers more than one kind of thing.

### Delete a request, keep its data

A table holds data as soon as something writes to it, which makes the table example a good one to delete:

```sh
kubectl apply -f platform/apis/table/example.yaml
kubectl -n hello-staging wait --for=condition=ready tables.back.lab/visits
aws dynamodb put-item --table-name hello-staging-visits --item '{"page":{"S":"/"},"seenAt":{"N":"1"}}'
kubectl -n hello-staging delete tables.back.lab visits
aws dynamodb scan --table-name hello-staging-visits --query Count
```

The request is gone within a second, and so is the managed resource Crossplane made for it, but the scan still counts the item: the Composition leaves Delete out of what the provider may do with a table, and a bucket's does the same. Apply the example again and it's ready in about a second, because nothing gets created: the new request finds the table where the old one left it, item and all.

```sh
kubectl apply -f platform/apis/table/example.yaml
kubectl -n hello-staging wait --for=condition=ready tables.back.lab/visits
aws dynamodb scan --table-name hello-staging-visits --query Count
```

Taking the data away is a step of its own, in the account, and `just reset` takes it for you ([why](decisions.md#a-services-data-outlives-its-request)).

### Change what a service was given

The platform runs Reloader so that a changed Secret reaches the pods already running: it watches the Secrets a pod reads and rolls the Deployment when one of them changes ([why](decisions.md#a-service-restarts-when-the-platform-changes-a-secret-it-handed-it)).

```sh
kubectl -n hello-staging patch secret hello-bucket --type merge -p '{"stringData":{"PROBE":"1"}}'
kubectl -n hello-staging get pods -w
```

The pods are replaced within a second or two. Crossplane leaves the extra key alone, owning only the fields it writes itself, so take it back out and the service rolls again:

```sh
kubectl -n hello-staging patch secret hello-bucket --type json -p '[{"op":"remove","path":"/data/PROBE"}]'
```

Reloader watches the namespaces the platform names for it, in `platform/apps/reloader.yaml`, and `just check` says which those are.

### Look at it as a developer

```sh
kubectl --context dev -n hello-staging get pods,buckets.back.lab
kubectl --context dev -n hello-staging delete pod --all
kubectl --context dev -n hello-staging get secret hello-bucket
kubectl --context dev get compositions
```

The first works, the other three are forbidden. A developer reads their team's namespaces, and the way to change anything is a pull request. In Argo CD, the same account sees the services and not the platform.

### Watch Git win

Start the watch first, in another terminal: the Application has a watch of its own on what it manages, and it's quicker than a minute.

```sh
kubectl -n hello-staging get deploy hello -w
```

Then, from here:

```sh
kubectl -n hello-staging scale deploy hello --replicas=3
```

It's back to one replica in about a second, before the extra pods are ever available, and the Application's events say the sync was its own (`automated`). This is what makes the cluster a copy of Git rather than a place where things are decided.

### Break it on purpose

```sh
kubectl -n cloud scale deploy aws --replicas=0
```

Within a minute the managed bucket stops being ready, and a few seconds later it stops being synced too: the provider keeps trying to create a bucket it can no longer see. hello's page says it can't reach its bucket, the request turns *Progressing*, and so does the service's Application, which is also what a first deploy looks like. *Degraded* is kept for a request Crossplane can't process at all ([why](platform-notes.md#argo-cd-cant-judge-the-platforms-own-kinds)), and this one it processes fine, so the error itself is a level further down:

```sh
kubectl -n hello-staging describe buckets.s3.aws.m.upbound.io
```

`--replicas=1` brings it back: about half a minute later the managed bucket is ready again, the request follows, and the buckets exist once more, because the emulator lost its state and Crossplane creates what it believes in.

Most of what goes wrong here has that shape, one handoff at a time: [when something doesn't work](troubleshooting.md).

## Changing the platform

These change files in your working copy and apply them without pushing. The loop, in the order you'd reach for it:

- `just render <api>` takes one of the folders under `platform/apis/` (`bucket`, `queue`, `table`, `cache`) and prints what that request would create, in a second and without a cluster, checked against the schemas.
- `just render-service [path]` does the same for a service through the platform's chart, for every stage, the way CI validates a pull request. Without an argument it renders `../back-hello/charts/hello`.
- `just diff <app>` takes an Argo CD Application (`apis` delivers the APIs in `platform/apis/`; `kubectl -n argocd get applications` lists them all) and shows what applying its folder from here would change in the cluster.
- `just local <app>` applies it instead of what Git says, and `just gitops` hands it back.

A change to `charts/app` still reaches the cluster by push ([why](platform-notes.md#a-local-sync-sees-one-source-only)), which is what [your own forks](#with-your-own-forks) are for.

### Change what a request is made of

The contract is the Secret; what's behind it is the platform's business. `Cache` composes a Valkey server, and swapping it for Redis is one line in `platform/apis/cache/composition.yaml`:

```diff
-                      image: valkey/valkey:9-alpine
+                      image: redis:8-alpine
```

Then the loop, which doesn't go through Git:

```sh
just render cache                                  # what it would create, checked against the schemas
just diff apis                                     # what applying the folder would change in the cluster
just local apis                                    # apply platform/apis/ from here, not from Git
kubectl apply -f platform/apis/cache/example.yaml
kubectl -n hello-staging wait --for=condition=ready caches.back.lab/sessions
kubectl -n hello-staging logs deploy/sessions-cache | grep -m1 version=
```

`cache` there is the folder under `platform/apis/`, and `apis` is the Argo CD Application that delivers all of them (`kubectl -n argocd get applications` lists the rest). Waiting on the request is the platform's own contract: it's ready when what it composed is, which the first time round includes pulling an image nobody here had asked for before.

That line names Redis. `just local` pauses Argo CD's enforcement for that folder and for the root Application that would restore it, so while it's on, the cluster and Git disagree on purpose. Handing it back is the half worth watching, because the request never stops being the same request:

```sh
just gitops                                        # hand it back to Git
kubectl -n hello-staging get pods -w               # the pod is replaced, then Ctrl-C
kubectl -n hello-staging logs deploy/sessions-cache | grep -m1 version=
```

Now it names Valkey. `just gitops` hands the folder back on the spot, and the rest follows from there: Argo CD compares against Git again, Crossplane writes the Deployment back, and the pod is replaced. Across both log lines the Secret keeps its keys, the Service keeps its address, and anything reading them notices nothing: that's what an API buys over a template. Then clean up after yourself:

```sh
kubectl -n hello-staging delete caches.back.lab sessions
git checkout platform/apis/cache/composition.yaml
```

### Move a service to the other front door

Traefik serves Ingress and Gateway API at once, and which one a stage uses is a line in `platform/apps/applicationset.yaml`. Staging already runs on a route; production is still on an Ingress:

```diff
                 - repo: https://github.com/hvpaiva/back-hello.git
                   stage: production
                   branch: main
-                  route: ingress
+                  route: gateway
```

```sh
just diff root                                     # one line of the ApplicationSet's list changes
just local root
kubectl -n hello-production get ingress,httproute
curl -s -o /dev/null -w '%{http_code}\n' http://hello.localhost
```

The Ingress goes and a route takes its place, at the same address and with one catch worth seeing: for about two tenths of a second, neither serves. Hammer it and you'll watch that happen; ask once and you'll never know it was there ([why](platform-notes.md#moving-a-service-between-front-doors-costs-a-gap)).

Nothing in back-hello changed, which is the whole point: the front door is the platform's business, and a service that had to be edited for this would be a service the platform can't migrate on its own. Then clean up after yourself:

```sh
just gitops
git checkout platform/apps/applicationset.yaml
```

### Add a field to an API

A `Cache` only takes a size. An eviction policy is a property in `platform/apis/cache/definition.yaml`:

```yaml
                evictionPolicy:
                  type: string
                  enum: [allkeys-lru, allkeys-lfu, volatile-lru, noeviction]
                  default: allkeys-lru
                  description: Which keys the cache drops when it runs out of room.
```

and one line in the Composition, where `--maxmemory-policy` is fixed:

```diff
-                        - allkeys-lru
+                        - {{ $xr.spec.evictionPolicy }}
```

`just render cache` fills in the default and shows it reaching the server's arguments, checked against the schemas. The description of `size` names the policy it used to be fixed at, so that sentence needs a word too: a field arrives with the documentation around it, or the next reader learns something that stopped being true.

An API also says no, and it's worth hearing it say so. Put a policy that isn't in the list into the example request and the render stops at the schema, before a cluster is involved. `Queue` refuses something else: a change it can't make to a queue that already exists.

```sh
kubectl apply -f platform/apis/queue/example.yaml
kubectl -n hello-staging patch queues.back.lab emails --type merge -p '{"spec":{"fifo":true}}'
```

```
The Queue "emails" is invalid: spec.fifo: Invalid value: true: A queue can't switch between standard and FIFO once it exists.
```

That sentence is in the definition (`self == oldSelf`), and the API server says it at `kubectl apply` time, whoever is applying and whatever they are applying from. Then clean up after yourself:

```sh
kubectl -n hello-staging delete queues.back.lab emails
git checkout platform/apis/cache
```

## With your own forks

Both of these reach the cluster by pushing, because Argo CD reads the repositories rather than your disk. The README says how to point the lab at your own copies.

### Resize a service and watch it promote

The developer's loop. In back-hello, set `size: medium` in `charts/hello/values-staging.yaml` and push. CI checks the values against the platform's chart before anything is built, Argo CD rolls staging out, and the page at http://hello.staging.localhost shows the new numbers itself: the platform hands every service its size, its replicas and its memory, and hello displays them. Then open a pull request from `staging` to `main` and merge it, and production runs the image staging ran, with production's values.

### Change the golden path for every service at once

`charts/app` decides how every service is deployed, and each service's Application reads it from Git, not from your disk ([why](platform-notes.md#a-local-sync-sees-one-source-only)). Change what `small` means in `charts/app/templates/_helpers.tpl`, push, and both stages of hello roll with it, without a single service repository changing.

`just render-service` is the fast half here. It renders a service through the chart for every stage, the same way the delivery workflow validates a pull request, and with the lab running it also puts each stage to the API server as a dry run.

A fork is also how to watch the platform refuse to throw data away. Take `bucket:` out of hello's `values.yaml` and push: the chart stops rendering the request, and Argo CD leaves it standing and says so, marking the Application OutOfSync with the request needing pruning. The bucket is still in the cloud account, and putting the line back adopts it again. That's `Prune=false,Delete=false` on the request, in `charts/app/templates/bucket.yaml`.
