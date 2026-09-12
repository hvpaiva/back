# Things to try

The lab is put together to be changed, not only read. These go from using the platform to changing
it, and each one says what you should see. Everything runs from this directory, where `mise.toml`
points the tools at the lab, and only the last one needs a fork.

## Ask the platform for something

Every API ships an example request next to its Composition:

```sh
kubectl apply -f platform/apis/queue/example.yaml
crossplane resource trace queues.back.lab emails -n hello-staging
kubectl -n hello-staging get secret emails-queue -o jsonpath='{.data.QUEUE_URL}' | base64 -d
```

In a few seconds the request is ready, two queues exist in LocalStack (`aws sqs list-queues`: the
queue and the dead-letter queue messages land in after five failed deliveries) and the Secret holds
what a service would read. `kubectl -n hello-staging delete queues.back.lab emails` takes all of it
back.

No service uses that one. `Bucket` is the only request the chart renders today, from `bucket:` in a
service's values; the others exist so the platform offers more than one kind of thing.

## Look at it as a developer

```sh
kubectl --context dev -n hello-staging get pods,buckets.back.lab
kubectl --context dev -n hello-staging delete pod --all
kubectl --context dev -n hello-staging get secret hello-bucket
```

The first works, the other two are forbidden. A developer reads their team's namespaces, and the
way to change anything is a pull request. In Argo CD, the same account sees the services and not
the platform.

## Watch Git win

```sh
kubectl -n hello-staging scale deploy hello --replicas=3
kubectl -n hello-staging get deploy hello -w
```

Argo CD puts it back within a minute, because the Application self-heals. This is what makes the
cluster a copy of Git rather than a place where things are decided.

## Change what a request is made of

The contract is the Secret; what's behind it is the platform's business. `Cache` composes a Valkey
server, and swapping it for Redis is one line in `platform/apis/cache/composition.yaml`:

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
kubectl -n hello-staging get pods -l app.kubernetes.io/name=sessions-cache
just gitops                                        # hand it back to Git
```

The Secret keeps its keys, the Service keeps its address, and anything reading them notices
nothing. That's what an API buys over a template. `just local` pauses Argo CD's enforcement for
that folder and for the root Application that would restore it, so while it's on, the cluster and
Git disagree on purpose.

## Add a field to an API

A `Cache` only takes a size. Adding an eviction policy is a property in
`platform/apis/cache/definition.yaml`, with an `enum` and a `default`, and one line in the
Composition, where `--maxmemory-policy` is currently fixed. `just render cache` shows the result
before anything is applied, and validates it against the schemas.

Then try taking it away again, or look at how `Queue` refuses to switch between standard and FIFO
(`self == oldSelf` in its definition). An API says no to the changes the thing behind it can't
make, and it says so at `kubectl apply` time, with a message the platform wrote.

## Break it on purpose

```sh
kubectl -n localstack scale deploy localstack --replicas=0
```

Within a minute the managed bucket stops being ready, the request turns Degraded in Argo CD's tree
and hello's page says it can't reach its bucket, while the service's Application stays Healthy: an
Application's health only counts its own resources. `--replicas=1` brings everything back, because
LocalStack lost its state and Crossplane creates the buckets again.

Most of what goes wrong here has that shape, one handoff at a time:
[when something doesn't work](troubleshooting.md).

## Resize a service and watch it promote

The developer's loop, and the first one that needs your own forks (see the README). In back-hello,
set `size: medium` in `charts/hello/values-staging.yaml` and push. CI checks the values against the
platform's chart before anything is built, Argo CD rolls staging out, and the page at
http://hello.staging.localhost shows the new numbers itself: the platform hands every service its
size, its replicas and its memory, and hello displays them. Then open a pull request from `staging`
to `main` and merge it, and production runs the image staging ran, with production's values.

## Change the golden path for every service at once

`charts/app` decides how every service is deployed, and each service's Application reads it from
Git, so this one goes through your own forks too: Argo CD syncs only single-source Applications
from disk, and a service's has two, the chart and its own values. Change what `small` means in
`charts/app/templates/_helpers.tpl`, push, and both stages of hello roll with it, without a single
service repository changing.

`just render-service` is the fast half here. It renders a service through the chart for every
stage, the same way the delivery workflow validates a pull request, and with the lab running it
also puts each stage to the API server as a dry run.

A fork is also how to watch the platform refuse to throw data away. Take `bucket:` out of hello's
`values.yaml` and push: the chart stops rendering the request, and Argo CD leaves it standing and
says so, marking the Application OutOfSync with the request needing pruning. The bucket is still in
LocalStack, and putting the line back adopts it again. That's `Prune=false,Delete=false` on the
request, in `charts/app/templates/bucket.yaml`.
