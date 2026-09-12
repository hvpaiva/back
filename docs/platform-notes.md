# Platform notes

Things that aren't obvious until they bite, collected while building the lab. Each one is small; together they're most of the work of putting these tools together.

## Argo CD can't install itself

Something has to install Argo CD before it can manage anything. Here Helm installs it once (`just argocd`), and an Application in `platform/apps/argocd.yaml` then adopts that installation. Adoption only works if the Application renders exactly what Helm installed: same chart version, same release name, same values file. Get one of them wrong and Argo CD creates a second copy of itself next to the first.

The root Application has a bootstrap problem of its own: it belongs to the `platform` project, which it creates. `just argocd` applies the projects before root, and root keeps them in sync from then on.

## Closing the default project takes every field

Argo CD creates a `default` project that allows everything, and an Application that names no project lands there. The lab closes it in `platform/apps/projects.yaml`, and every list has to be there, even the empty ones: the first apply to an object nobody applied before only changes the fields the manifest has. Left out, `clusterResourceWhitelist` would stay `*`.

## A local cluster gets no webhooks

Argo CD learns about new commits through a GitHub webhook or by polling. GitHub can't reach a cluster on a laptop, so the lab polls every minute (the default is up to three). The Refresh button in the UI, or `argocd app get <app> --refresh`, checks right away.

## Health depends on someone else writing status

Argo CD decides whether a resource is healthy by reading its status, which another controller writes. An Ingress, for instance, only counts as healthy once it has an address, and in a cloud the load balancer fills that in. kind has no load balancer, so every Ingress stayed *Progressing* forever until Traefik was told to publish `127.0.0.1` (`cluster/traefik-values.yaml`). The same thing happens with custom resources, which Argo CD doesn't know how to judge at all without a health check written for them.

## Some objects are too big for the default apply

Client-side apply, Argo CD's default, keeps a copy of each object in an annotation limited to 256 KB. Argo CD's own CRDs are bigger than that, so the Application that manages Argo CD uses `ServerSideApply=true`.

## "Permission denied" can mean "doesn't exist"

Asking Argo CD for an Application that doesn't exist returns `permission denied`, even for an admin. It's deliberate: a user without access can't find out which Applications exist by guessing names. Right after a push that adds an Application, refresh the Application that creates it (usually `root`), not the new one.

## One broken service can stop them all

The ApplicationSet that creates the services' Applications reads fields from each service's `values.yaml`, such as `application.name`, and it's set to fail on a missing field (`missingkey=error`) rather than create an Application with an empty name. The failure isn't scoped to that service: generation stops for every service until the file is fixed. The chart's schema can't catch this one: it runs when an Application syncs, and that service never gets an Application. Only a check before the change is merged would.

## A dry run checks the shape, not the content

`kubectl apply --dry-run=server` validates an Application against its schema, which catches a misspelled field. It doesn't check that the repository, branch or path it points to exists. Those errors appear later, as a condition on the Application in Argo CD.

## An Application applies every file in its folder

The `apis` Application syncs `platform/apis/` recursively, so the example request each API ships
next to its Composition would be created in the cluster on the next sync, in whatever namespace it
names. `directory.exclude` keeps them out. What a folder would apply is easy to check before
pushing it: `argocd app diff <app> --local <path>` renders the folder as it is on disk and compares
it with the cluster. That command and `just local` read the folder from disk but the Application's
own settings from the cluster, so a change to the Application itself, this exclusion included, only
counts once it's pushed.

On a cluster that was already running, the commit that added both the examples and the exclusion
applied them in that order. Two Applications are involved, root for the `apis` Application and
`apis` for the folder, and `apis` synced the new files before root handed it the exclusion. The
four requests it created then stayed, because the APIs are never pruned, until they were deleted by
hand. A cluster built after that commit never sees it: the Application is created with the
exclusion already in it.

## Letting teams create their namespaces

Services run in namespaces that don't exist yet, so their Applications create them (`CreateNamespace=true`). A namespace is a cluster-wide object, which the `apps` project would otherwise reject. The project allows it by name: `*-staging` and `*-production`, and nothing else.

## Telling GitHub what was deployed

Argo CD's GitHub notifications only sign in as a GitHub App, not with a personal token. The app's key lives in a Secret created by `just notifications` from a local file. The Argo CD chart normally creates that Secret itself, empty, so the lab turns that off and the Secret belongs to whoever creates it, outside Git.

Two settings in the notification template are easy to get wrong. A service's Application has two sources, the platform's chart and the service's repository, so the status has to go to the second one (`sources[1]` and its revision), not to the chart's repository. And `autoMerge` must be off: on, GitHub tries to merge the default branch into the branch being deployed.

## A reusable workflow has the caller's permissions

The delivery workflow pushes commits and images, but it can't grant itself permission to: it runs with the token of the service's CI, limited to what the calling job allows. Every service's CI has to grant `contents: write` and `packages: write` to the job that calls `delivery.yaml`.

## A failing check doesn't block anything on its own

Validation fails the pull request's check, but GitHub still lets someone merge it. Making the check required is a branch protection rule, and on the stage branches it has a catch: CI pushes deploy commits there itself, so the rule needs an exemption for it.

## A green check before the code is live

With code and configuration in the same branch, one change reaches staging as two commits: the developer's, then the one CI makes after building the image. Argo CD applies both, so both get a green `argocd/hello-staging` check and a staging deployment on GitHub. The first one only means the configuration at that commit is applied, and it still points to the previous image. The code is live when CI's commit, the one naming the new image, gets its check. Running a separate branch that only CI writes to would avoid this, at the cost of one more moving part.

## A promotion can conflict with edits near the image

On `main`, CI rewrites `image:` in `values-production.yaml` on every promotion, and `staging` never receives those commits. An edit on `staging` right next to that line (here, the comment above it) conflicts the next time `staging` is merged into `main`. Merge `main` into `staging` and keep `main`'s image, which the promotion overwrites anyway. Keeping the line CI owns away from what people edit, or in a file of its own, avoids the conflict altogether.

## Commits from CI don't trigger CI

The service's CI commits the new image to its own repository. Commits pushed with the workflow's built-in token don't start new workflow runs, which is what keeps that from looping.

## A starting provider fails the sync that installs it

Argo CD's built-in health check for Crossplane providers reports *Degraded* while the provider's pod starts, and a *Degraded* resource fails the sync in progress. The first install got through only on Argo CD's automatic retries (five by default), which a slow image pull can run out of. `platform/argocd/values.yaml` replaces that check with one that stays *Progressing* until the provider is installed and healthy.

## An endpoint override only covers the services it lists

The AWS provider sends a service's calls to a custom endpoint only if that service is in the ProviderConfig's `endpoint.services`. With the list empty, the lab's first test bucket went to AWS itself, which rejected the dummy key. `platform/crossplane/localstack.yaml` lists `s3` and `s3control`, and any AWS service the platform starts using has to be added there first.

## S3 needs S3 Control, and S3 Control needs wildcard DNS

To read a bucket's tags, the provider calls S3 Control at `<account-id>.<endpoint>`, and it always has an account ID (`000000000000` with LocalStack). AWS has DNS for those names; the cluster didn't, so the bucket never became ready. `cluster/coredns.yaml` adds a CoreDNS rule that answers `<account-id>.localstack.localstack.svc` with LocalStack's Service.

## An external name isn't always a name

Crossplane's `crossplane.io/external-name` annotation says what a managed resource is called in the cloud, and for an S3 bucket that's the bucket's name. SQS identifies a queue by its URL instead, so the provider overwrote the annotation with the URL it got back, and the queues, which set no `name`, came up called `terraform-1ac4f3bd49da...`: the random name the Terraform provider these are generated from picks. The Queue Composition names them in a field, `forProvider.name`. Which of the two a resource uses is in the provider's external-name configuration, not in its schema.

## Unquoted, N is false

A DynamoDB key is typed with a single letter: S, N or B. Written into a Composition's template without quotes, `type: N` reached the provider as the boolean `false`, because the YAML parser reads a bare N that way. `crossplane resource validate`, run against the provider's schema, caught it as "must be of type string". Anything a template writes that could be read as a boolean or a number needs quoting.

## A Composition has no memory

A Composition runs from scratch on every reconcile, so a password generated in its template would be a different password every time, and the service would be left holding the old one. The `Cache` Composition reads the password back from the Secret it composed and generates one only when there's nothing to read. Anything the platform can't recompute has to come from somewhere that keeps it: what was already composed, or whatever generated it in the first place.

## Argo CD can't judge the platform's own kinds

Argo CD ships health checks for Crossplane's kinds and for the providers' managed resources, but not for the APIs a platform defines. With LocalStack turned off, hello's bucket went unreachable, the provider marked the managed bucket not ready (*Degraded* in Argo CD's tree), Crossplane marked the request not ready, and the `hello-staging` Application stayed *Healthy*: an Application's health only counts its own resources, and to Argo CD the request had no health at all. `platform/argocd/values.yaml` adds a check for the platform's kinds: *Healthy* when the request is ready, *Degraded* when Crossplane can't process it, *Progressing* otherwise. It takes one key per kind: Argo CD's documented wildcards (`back.lab_*`) aren't valid ConfigMap keys, and the first attempt left Argo CD failing to update itself. It also hides the ProviderConfigUsages, one per managed resource, which crowded the tree without saying anything.

## Inactive resource types look like they're provisioning

The S3 provider ships 50 resource types and the activation policy turns on two; the rest get a definition but no CRD. Argo CD's built-in check for Crossplane's kinds knows nothing about activation, so under the provider in Argo CD's tree, 48 definitions stayed *Progressing*, "Provisioning ...", for good. Nothing was wrong, and the Application stayed *Healthy*: it only counts its own resources. `platform/argocd/values.yaml` shows inactive definitions as *Suspended*. The new check only showed after a hard refresh of the Application (`argocd app get crossplane --hard-refresh`); until then, the definitions, which never change, kept the health the old check had given them.

## Deleting a namespace strands its managed resources

Delete a namespace that still holds a managed resource and the resource stays behind, stuck on its finalizer, and so does the namespace. To reach the cloud, the provider first records that the resource uses its ProviderConfig, in an object it creates in the same namespace; a terminating namespace refuses new objects, so the provider never gets as far as deleting anything. Restarting it doesn't help. It's an open Crossplane bug ([crossplane-runtime#1150](https://github.com/crossplane/crossplane-runtime/issues/1150)). Delete the requests first, then the namespace. If one is already stuck, delete the external resource by hand if it still exists, then remove the finalizer.

## Waves in an app of apps don't wait by default

Sync waves order the resources of one Application, and Argo CD waits for each wave to be healthy before the next. But Argo CD 1.8 stopped assessing the health of Applications themselves, so a root Application applies all its children at once. The services would then be created before the APIs their requests use. `platform/argocd/values.yaml` restores that health check, and root waits: Crossplane, then the APIs, then the services. The cost is that a child that never becomes healthy holds back every later wave. And a child can look healthy for a moment between its own waves: on a fresh install, root moved on as soon as Crossplane itself was up, before its providers were installed. Harmless here, since the APIs only need Crossplane and the services' requests wait for the providers, but a child's health doesn't mean it has finished syncing.

## Drift is checked every ten minutes

A provider compares each managed resource with the cloud every ten minutes by default, so a bucket deleted by hand comes back up to ten minutes later. The lab sets one minute (`--poll=1m`, in `platform/crossplane/providers.yaml`), which costs an API call per resource per minute: fine here, worth measuring with thousands of resources.

## The argocd CLI and Traefik

Before logging in, `argocd login` probes the server for TLS. Traefik answers that probe with its default certificate, even on port 80, and the CLI then stops to ask whether to proceed. `just argocd-login` skips the probe (`--skip-test-tls`), and `ARGOCD_OPTS` in `mise.toml` sets `--grpc-web --plaintext` for every command.

`just argocd-login <user>` names the CLI's context after the user. To switch, log in again: `argocd context <name>` writes a file under `~/.config/argocd`, outside the lab's own config, and fails.

## Argo CD has permissions of its own

Argo CD reads the cluster with its own ServiceAccount and decides what each user sees with its own RBAC, per Application rather than per resource: whoever can see an Application sees every resource in its tree. For `dev`, that's what kubectl's `view` shows in its services' namespaces, plus the Secrets' metadata and key names, which kubectl hides; the values are masked (`++++++++`). Argo CD only masks the `data` and `stringData` of Secrets, though. A password in a ConfigMap, or in a custom resource's spec or status, would show in full, which is why the platform's APIs hand out credentials in Secrets only. The two systems also drift apart as teams arrive: every developer sees every service in the `apps` project, logs included, while kubectl keeps each team to its own namespaces. A project per team would keep them aligned.
