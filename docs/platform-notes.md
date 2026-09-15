# Platform notes

Things that aren't obvious until they bite, collected while building the lab, grouped by where they happen. Each one is small; together they're most of the work of putting these tools together.

## Installing Argo CD with Argo CD

### Argo CD can't install itself

Something has to install Argo CD before it can manage anything. Here `just argocd` renders its Helm chart once and applies the result, and an Application in `platform/apps/argocd.yaml` then adopts that installation. Adoption only works if the Application renders exactly what was applied: same chart version, same release name, same values file. Get one of them wrong and Argo CD creates a second copy of itself next to the first.

That first apply is server-side and uses `argocd-controller`, the field manager Argo CD applies with, so Argo CD owns every field from the start. Installed with `helm install`, Helm co-owns all of them, and a field only leaves an object once its last owner stops applying it: something removed from `platform/argocd/values.yaml` then stays in the cluster while Argo CD reports Synced, which is what five per-kind health keys did after a wildcard replaced them. A lab installed that way lists `helm` among argocd-cm's field managers, `just argocd` warns about it, and `just down && just up` reinstalls it with one owner. What the chart's install hooks used to order now settles on its own: the Job that creates Redis's password is refused until its ServiceAccount exists, and Redis fails until that Secret does, once or twice each.

The root Application has a bootstrap problem of its own: it belongs to the `platform` project, which it creates. `just argocd` applies the projects before root, and root keeps them in sync from then on.

### Closing the default project takes every field

Argo CD creates a `default` project that allows everything, and an Application that names no project lands there. The lab closes it in `platform/apps/projects.yaml`, and every list has to be there, even the empty ones: the first apply to an object nobody applied before only changes the fields the manifest has. Left out, `clusterResourceWhitelist` would stay `*`.

Applying `platform/apps/projects.yaml` also warns every time, because Argo CD created the object without the annotation client-side apply keeps its copy in. `--server-side` trades that one warning for three, one per project, about the same annotation conflicting with Argo CD's own controller.

### Some objects are too big for the default apply

Client-side apply, Argo CD's default, keeps a copy of each object in an annotation limited to 256 KB. Argo CD's own CRDs are bigger than that, so the Application that manages Argo CD uses `ServerSideApply=true`.

## Sync order

### Waves in an app of apps don't wait by default

Sync waves order the resources of one Application, and Argo CD waits for each wave to be healthy before the next. But Argo CD 1.8 stopped assessing the health of Applications themselves, so a root Application applies all its children at once. The services would then be created before the APIs their requests use. `platform/argocd/values.yaml` restores that health check, and root waits: Crossplane, then the APIs, then the services. The cost is that a child that never becomes healthy holds back every later wave. And a child can look healthy for a moment between its own waves: on a fresh install, root moved on as soon as Crossplane itself was up, before its providers were installed. Harmless here, since the APIs only need Crossplane and the services' requests wait for the providers, but a child's health doesn't mean it has finished syncing.

### A wave orders one Application, not what another one creates

Sync waves order the resources of a single sync, and between waves Argo CD waits for what it just applied to become healthy. Root uses that to bring the platform up in order, and it works where health covers what an object delivers: it sat on `Application/apis` for thirty seconds while Crossplane settled. An ApplicationSet counts as healthy once it has generated its Applications, without waiting for them to sync, so the wave holding it was over in under a second, and the Applications it generates sync on their own time, after root has already finished.

Reloader was where that late sync showed. Its chart puts a Role in each namespace it watches, and those namespaces belong to the services' own Applications, so on a new cluster its first sync could land before them: two RBAC objects reported `SyncFailed` with `namespaces "hello-staging" not found`, and the Application called itself Healthy while staying OutOfSync until the namespace appeared.

Holding the wave until the services sync doesn't cure Reloader's failed first sync. With a health check that keeps the ApplicationSet Progressing until every Application it generated has synced, root's operation waits for as long as one service can't sync, and Argo CD starts no other sync of root meanwhile, so the platform's own changes stop landing. Holding the wave also releases late: an ApplicationSet refreshes the sync status it lists only when it reconciles itself, which for the lab's services is every three minutes. The lab turns the chart's RBAC off instead. A ClusterRole ships with Reloader and each service's chart binds it in its own namespace; a Reloader that starts before that binding exists retries with a backoff and picks the namespace up within half a minute of it, without restarting.

## What Argo CD compares and applies

### A local cluster gets no webhooks

Argo CD learns about new commits through a GitHub webhook or by polling. GitHub can't reach a cluster on a laptop, so the lab polls every minute (the default is up to three). The Refresh button in the UI, or `argocd app get <app> --refresh`, checks right away.

### An empty map is a difference that never goes away

Eleven of Kyverno's CRDs come from a subchart that writes `labels` and `annotations` onto each from values that are empty by default, so what Git renders carries an empty map for both. The API server stores neither, so Argo CD compares a field that exists in the manifest with one that doesn't exist in the cluster, and the Application reports eleven resources OutOfSync for good. `kubectl diff` on the same manifest prints nothing at all: to the API server the two are identical.

Filling the maps in from the chart doesn't settle the difference, because those values belong to the subchart and the parent's own `crds.customLabels` feeds a different one. `ignoreDifferences` does, on both fields at once. Covering only `labels` leaves `annotations` differing and the Application stays exactly as OutOfSync as it was, which reads like the mechanism not working rather than like half of it being applied.

### A dry run checks the shape, not the content

`kubectl apply --dry-run=server` validates an Application against its schema, which catches a misspelled field. It doesn't check that the repository, branch or path it points to exists. Those errors appear later, as a condition on the Application in Argo CD.

### An Application applies every file in its folder

The `apis` Application syncs `platform/apis/` recursively, so the example request each API ships next to its Composition would be created in the cluster on the next sync, in whatever namespace it names. `directory.exclude` keeps them out. What a folder would apply is easy to check before pushing it: `argocd app diff <app> --local <path>` renders the folder as it is on disk and compares it with the cluster. That command and `just local` read the folder from disk but the Application's own settings from the cluster, so a change to the Application itself, this exclusion included, only counts once it's pushed.

### A local sync sees one source only

`argocd app sync --local` and `argocd app diff --local` read the folder you point at and nothing else, so an Application with two sources loses the other one, without saying so. Asked to diff a service against `charts/app`, Argo CD ran `helm template` with no values at all and stopped at the chart's own schema, complaining that `application.name` was empty; asked to diff the Argo CD Application against `platform/argocd`, it went looking for a `Chart.yaml` that was never there. Only an Application with a single source pointing at a folder of this repository can be synced from disk, which here means `apis`, `rbac` and `root`. Everything else changes by pushing, and `just local` says which it is.

The CLI also warns that a local diff without `--server-side-generate` is deprecated, and that flag doesn't work here. The folder travels as a gRPC stream, and the repo server, which is what checks it, reports a checksum for an empty archive where the CLI declared a full one (`calc e3b0c442…`, the hash of nothing). The same failure comes back through Traefik and through a port-forward, as grpc-web and as plain gRPC, with and without `--local-repo-root`, so it isn't the transport. Until the flag works, the warning is what the loop costs.

### "Permission denied" can mean "doesn't exist"

Asking Argo CD for an Application that doesn't exist returns `permission denied`, even for an admin. It's deliberate: a user without access can't find out which Applications exist by guessing names. Right after a push that adds an Application, refresh the Application that creates it (usually `root`), not the new one.

## Health

### Health depends on someone else writing status

Argo CD decides whether a resource is healthy by reading its status, which another controller writes. An Ingress, for instance, only counts as healthy once it has an address, and in a cloud the load balancer fills that in. kind has no load balancer, so every Ingress stayed *Progressing* forever until Traefik was told to publish `127.0.0.1` (`cluster/traefik-values.yaml`). The same thing happens with custom resources, which Argo CD doesn't know how to judge at all without a health check written for them.

### A starting provider fails the sync that installs it

Argo CD's built-in health check for Crossplane providers reports *Degraded* while the provider's pod starts, and a *Degraded* resource fails the sync in progress. The first install got through only on Argo CD's automatic retries (five by default), which a slow image pull can run out of. `platform/argocd/values.yaml` replaces that check with one that stays *Progressing* until the provider is installed and healthy.

### Argo CD can't judge the platform's own kinds

Argo CD ships health checks for Crossplane's kinds and for the providers' managed resources, but not for the APIs a platform defines. With the cloud account turned off, hello's bucket went unreachable, the provider marked the managed bucket not ready (*Degraded* in Argo CD's tree), Crossplane marked the request not ready, and the `hello-staging` Application stayed *Healthy*: an Application's health only counts its own resources, and to Argo CD the request had no health at all. `platform/argocd/values.yaml` adds a check for the platform's kinds: *Healthy* when the request is ready, *Degraded* when Crossplane can't process it, *Progressing* otherwise. It covers every kind in the group, the ones added later included, with one wildcard, `back.lab/*`, which only the older single `resource.customizations` key accepts: as a key of its own, `resource.customizations.health.back.lab_*` isn't a valid ConfigMap key, and a first attempt with it left Argo CD failing to update itself. A kind that needs a different check can still have its own key, which wins over the wildcard. The check also hides the ProviderConfigUsages, one per managed resource, which crowded the tree without saying anything.

That mapping from conditions to health is Argo CD's own. Asked about a managed resource with `Synced=True` and `Ready=False`, its bundled check answers *Progressing*, "Provisioning ...", and about the same resource with `Synced=False` it answers *Degraded* with the provider's message. `argocd admin settings resource-overrides health <object> --argocd-cm-path <configmap>` gives both answers without a cluster. It answers for a kind no check covers too, "Health script is not configured", with the exit status of a success, so a test has to read the status it prints. And it takes the invalid wildcard key without a complaint and applies it, which is why `just test` also puts the ConfigMap to the API server when one answers. Copying it has one consequence worth knowing: while a dependency is down, the request stays *Progressing* for as long as the outage lasts, which reads like a first deploy rather than a failure, and the GitHub notification for a degraded Application never fires. A health check can't decide that on its own, because Argo CD's Lua has no clock (`os.time()` fails with "attempt to index a non-table object(nil)"), so anything based on how long something has been Progressing belongs in alerting instead.

### Inactive resource types look like they're provisioning

The S3 provider ships 50 resource types and the activation policy turns on two; the rest get a definition but no CRD. Argo CD's built-in check for Crossplane's kinds knows nothing about activation, so under the provider in Argo CD's tree, 48 definitions stayed *Progressing*, "Provisioning ...", for good. Nothing was wrong, and the Application stayed *Healthy*: it only counts its own resources. `platform/argocd/values.yaml` shows inactive definitions as *Suspended*. The new check only showed after a hard refresh of the Application (`argocd app get crossplane --hard-refresh`); until then, the definitions, which never change, kept the health the old check had given them.

### A database that can't grow its disk still reads healthy

kind's storage class can't expand a volume. A CloudNativePG cluster that was asked for a bigger disk got no further than that step. The operator logged `error while changing PVC storage requirement` about every 40 seconds, created no new instance and applied no new memory, and the cluster still read as healthy, so the request stayed Ready too. Asking for the old size back was refused, because CloudNativePG compares a storage change with the size it was last given, not with the volume. The only sign was the request's INSTANCES column, which counts the instances ready out of those the size asks for and read `1/2`. That's why a database's disk is set once, when the database is created ([why](decisions.md#a-databases-size-can-change-later-its-disk-cant)).

## Services and teams

### One broken service can stop them all

The ApplicationSet that creates the services' Applications reads fields from each service's `values.yaml`, such as `application.name`, and it's set to fail on a missing field (`missingkey=error`) rather than create an Application with an empty name. The failure isn't scoped to that service: generation stops for every service until the file is fixed. The chart's schema can't catch this one: it runs when an Application syncs, and that service never gets an Application. Only a check before the change is merged would.

### Letting teams create their namespaces

Services run in namespaces that don't exist yet, so their Applications create them (`CreateNamespace=true`). A namespace is a cluster-wide object, which the `apps` project would otherwise reject. The project allows it by name: `*-staging` and `*-production`, and nothing else.

### Moving a service between front doors costs a gap

Traefik serves Ingress and Gateway API at the same time, so a service moves from one to the other by changing a parameter, and nothing about the service changes. The move is not seamless, though. Argo CD deletes the Ingress and creates the HTTPRoute in the same sync, and Traefik takes a moment to serve the new one, so the address stops answering for about two tenths of a second: measured twice, 28 failed requests out of 1225 on one stage and 18 out of 645 on the other. One request per route would have found nothing, which is how a migration like this gets called seamless.

The gap belongs to the swap, not to the route. A route created on its own starts serving within 66 to 179 ms of `kubectl apply`, and only the first Gateway route a cluster ever gets costs an extra miss, while Traefik's provider wakes up.

### Argo CD has permissions of its own

Argo CD reads the cluster with its own ServiceAccount and decides what each user sees with its own RBAC, per Application rather than per resource: whoever can see an Application sees every resource in its tree. For `dev`, that's what kubectl's `view` shows in its services' namespaces, plus the Secrets' metadata and key names, which kubectl hides; the values are masked (`++++++++`). Argo CD only masks the `data` and `stringData` of Secrets, though. A password in a ConfigMap, or in a custom resource's spec or status, would show in full, which is why the platform's APIs hand out credentials in Secrets only. The two systems also drift apart as teams arrive: every developer sees every service in the `apps` project, logs included, while kubectl keeps each team to its own namespaces. A project per team would keep them aligned.

## Crossplane and the cloud account

### An endpoint override only covers the services it lists

The AWS provider sends a service's calls to a custom endpoint only if that service is in the ProviderConfig's `endpoint.services`. With the list empty, the lab's first test bucket went to AWS itself, which rejected the dummy key. `platform/crossplane/cloud.yaml` lists `s3` and `s3control`, and any AWS service the platform starts using has to be added there first.

### S3 needs S3 Control, and S3 Control needs wildcard DNS

To read a bucket's tags, the provider calls S3 Control at `<account-id>.<endpoint>`, and it always has an account ID (`000000000000` against the lab's emulator). AWS has DNS for those names; the cluster didn't, so the bucket never became ready. `cluster/coredns.yaml` adds a CoreDNS rule that answers `<account-id>.aws.cloud.svc` with the emulator's Service. Swapping the emulator didn't retire the rule: with it removed, the bucket stops reconciling and says why, `operation error S3 Control: ListTagsForResource … no such host`.

### An external name isn't always a name

Crossplane's `crossplane.io/external-name` annotation says what a managed resource is called in the cloud, and for an S3 bucket that's the bucket's name. SQS identifies a queue by its URL instead, so the provider overwrote the annotation with the URL it got back, and the queues, which set no `name`, came up called `terraform-1ac4f3bd49da...`: the random name the Terraform provider these are generated from picks. The Queue Composition names them in a field, `forProvider.name`. Which of the two a resource uses is in the provider's external-name configuration, not in its schema.

The two queues also carry a `metadata.name` of their own, the request's and the request's plus `-dlq`, so a trace says which is which instead of showing two generated names.

### Unquoted, N is false

A DynamoDB key is typed with a single letter: S, N or B. Written into a Composition's template without quotes, `type: N` reached the provider as the boolean `false`, because the YAML parser reads a bare N that way. `crossplane resource validate`, run against the provider's schema, caught it as "must be of type string". Anything a template writes that could be read as a boolean or a number needs quoting.

### A Composition has no memory

A Composition runs from scratch on every reconcile, so a password generated in its template would be a different password every time, and the service would be left holding the old one. The `Cache` Composition reads the password back from the Secret it composed and generates one only when there's nothing to read. The `Database` Composition does the same with the disk, which it takes from the cluster it already made rather than from the size. Anything the platform can't recompute has to come from somewhere that keeps it: what was already composed, or whatever generated it in the first place.

### A Composition can't rename what it made

A Composition that starts giving a resource another name doesn't rename the one it made. A Secret whose name changed in the template kept its old name for the four minutes it was watched, and the request kept pointing at it, so whatever else the template built from the new name, a reference or an address, pointed at nothing. Filing the resource under another key in the template is worse: Crossplane deleted the Secret within a second and created it again, which for a database's cluster would be the database. So the Compositions read the names their resources already have, and a cluster keeps the key it was created under.

### A render sees only what a Composition makes from nothing

`crossplane composition render` starts from an empty cluster unless it's told otherwise, and a Composition that decides from what already exists shows only its first step. The database's example renders a `Bucket` and nothing else: the object store waits for the bucket's Secret, the Postgres cluster for a ready bucket, the backup schedule for working archiving, and the service's Secret for the one CloudNativePG writes. A mistake in any of those passes a render of the example and fails in the cluster. `-o` hands render the resources the Composition already made and `-e` the ones it reads, and the scenarios in `tests/apis/` keep a set of both for each API, which is how a render of the database reaches all six.

### A resource that reports no readiness never counts as ready

function-auto-ready marks a request ready once everything it composed is. Neither CloudNativePG's ScheduledBackup nor the backup plugin's ObjectStore reports a `Ready` condition, and a Database composing them stayed *Creating*, "Unready resources: schedule, store", however long they had existed. The Composition marks both ready itself with function-go-templating's `gotemplating.fn.crossplane.io/ready` annotation, and uses the same annotation to mark a database's cluster not ready while its archiving fails.

### Drift is checked every ten minutes

A provider compares each managed resource with the cloud every ten minutes by default, so a bucket deleted by hand comes back up to ten minutes later. The lab sets one minute (`--poll=1m`, in `platform/crossplane/providers.yaml`), which costs an API call per resource per minute: fine here, worth measuring with thousands of resources.

### An XRD the API server refuses shows no error

Crossplane turns each XRD into a CRD, and the API server checks that CRD only when Crossplane creates it. A CEL rule the server estimates as too expensive gets the CRD refused. A rule that ranked sizes with `['small', 'medium', 'large'].indexOf(self)` was refused that way ("estimated rule cost exceeds budget by factor of more than 100x"), with or without a `maxLength` on the field. The XRD then had no ESTABLISHED status, applying a request failed with "no matches for kind", and Crossplane's logs said nothing. The reason was only in a warning event on the XRD, which `kubectl describe xrd <name>` shows. A server dry run of the XRD passes, since the XRD itself is valid. `just render` converts the XRD to its CRD with `crossplane xrd convert` and puts that CRD to the API server, which is where the refusal shows. The same ranking written as a lookup in a map, `{'small': 0, 'medium': 1, 'large': 2}[self]`, costs little enough.

### A Composition reading someone else's resource asks for it by name

A Composition can read a resource it didn't create, like the Secret CloudNativePG writes with a database's credentials. function-go-templating finds such a resource by name and namespace, or by labels. By labels, the lookup ignores the namespace and matches across the whole cluster, so a request could end up reading another namespace's Secret. The `Database` Composition asks for the Secret by name, in the request's namespace.

## Backups

### Postgres reports archiving as working with nowhere to archive to

CloudNativePG sets a cluster's `ContinuousArchiving` condition from what Postgres's archive command returns, and a cluster with no backups configured returns success. hello's databases, which had run for two hours without backups, had the condition at `True` before the plugin arrived. The backup schedule the Composition created on that signal took its first backup before the operator saw the plugin in the cluster's spec, and it failed: "cannot proceed with the backup as the cluster has no plugin configured". That failure is final, and the next attempt would have been at midnight. The operator's code waits for a pod to be ready before backing it up, but not for the plugin to be in it, so a backup that reached a pod still waiting to restart with the plugin would fail for good as well. The Composition creates the schedule once the plugin has reported from the primary, which it does as its container starts there, or straight away for a database created with backups in place, whose pods have the plugin from the start.

### A database can't archive into backups that aren't its own

Before its first archive, the Barman Cloud plugin checks that the folder it archives into is empty, and refuses otherwise ("Expected empty archive"). That's what stops an empty database, created where an earlier one left its backups, from writing over them: its archiving fails, and the Composition keeps it not ready. A backup started by hand on that database wrote its first file into the old folder and never finished; a later restore from the folder ignored it. The same check refuses a database restored from its own folder, since the folder holds the very backups it came from: the job that restores it failed and was retried for as long as it ran. The annotation `cnpg.io/skipEmptyWalArchiveCheck: enabled` skips the check, and the Composition sets it only on a database it restores. The restored database goes on archiving into the same folder, on a new timeline, and the old timeline's files stay as they were.

### A restore can start from a timeline another restore left behind

Every restore branches a new timeline off the database's history, and it picks its full backup by time: the latest one before the moment asked for, or the latest of all. In a drill, a database was restored to its latest point, on a timeline that then took a full backup of its own, and restored again to a moment before that first restore, which branched a third timeline off the first. It was lost a couple of seconds later, before the third timeline had a full backup. A restore to the latest point then started from the second timeline's backup, and Postgres refused to follow the third timeline from there, "requested timeline 3 is not a child of this server's history", on every retry of the job that restores it. Nothing was lost: a restore to a moment just before that backup started from the first timeline's, which the third one does descend from, and came back with the data. A restored database takes a full backup of its own within about half a minute, which is how long that window stays open.

## Deleting requests

### A request goes before what it composed does

Delete a request and it leaves the API almost at once: gone by the first reading, 68 ms after the delete, finalizer and all. What it composed takes longer. A managed resource the provider has to delete in the cloud stayed 6 s in one run and about 30 s in three others, inside the provider's one-minute poll; a bucket or a table, which it only lets go of, left within about a second. So waiting for the request to disappear hands back a lab that is still tearing down, and re-applying the same request then races a resource that is still terminating. `just reset` waits on the `crossplane.io/composite` label instead, which is what the composed resources carry.

### A request another request composed carries no mark from Argo CD

Argo CD annotates what it delivers and nothing else, so the `Bucket` a `Database` composes for its backups has no annotation even when the database came from Git. A reset that read the missing annotation as "applied by hand" deleted hello's backup buckets, and the backups in them; the databases went on archiving into the empty buckets the platform recreated moments later, with nothing to restore from until a new full backup. What sets a composed request apart is a controller reference to the request that composed it, and `just reset` leaves those to their owner.

### Deleting a namespace can strand its managed resources

Delete a namespace that still holds managed resources and some of them can stay behind, stuck on their finalizer, and the namespace with them. Before every reconcile, the provider records that the resource uses its ProviderConfig, in an object it keeps in the same namespace. The namespace controller deletes those records along with everything else, and a terminating namespace refuses new ones, so from then on the provider fails before doing anything, without a word in the resource's status. A bucket or a table can leave without touching the cloud account, since the platform never lets the provider delete them, but only if the provider got to it before its record went: in three namespaces, one of two stayed stuck, then two of four, then none. Restarting the provider doesn't help. It's an open Crossplane bug ([crossplane-runtime#1150](https://github.com/crossplane/crossplane-runtime/issues/1150)). Delete the requests first, then the namespace. If one is already stuck, remove its finalizer; whatever it created is still in the cloud account, and removing it there is a separate decision.

## GitHub and CI

### Telling GitHub what was deployed

Argo CD's GitHub notifications only sign in as a GitHub App, not with a personal token. The app's key lives in a Secret created by `just notifications` from a local file. The Argo CD chart normally creates that Secret itself, empty, so the lab turns that off and the Secret belongs to whoever creates it, outside Git.

Two settings in the notification template are easy to get wrong. A service's Application has two sources, the platform's chart and the service's repository, so the status has to go to the second one (`sources[1]` and its revision), not to the chart's repository. And `autoMerge` must be off: on, GitHub tries to merge the default branch into the branch being deployed.

### A reusable workflow has the caller's permissions

The delivery workflow pushes commits and images, but it can't grant itself permission to: it runs with the token of the service's CI, limited to what the calling job allows. Every service's CI has to grant `contents: write` and `packages: write` to the job that calls `service-delivery.yaml`.

### A failing check doesn't block anything on its own

Validation fails the pull request's check, but GitHub still lets someone merge it. Making the check required is a branch protection rule, and on the stage branches it has a catch: CI pushes deploy commits there itself, so the rule needs an exemption for it.

### A green check before the code is live

With code and configuration in the same branch, one change reaches staging as two commits: the developer's, then the one CI makes after building the image. Argo CD applies both, so both get a green `argocd/hello-staging` check and a staging deployment on GitHub. The first one only means the configuration at that commit is applied, and it still points to the previous image. The code is live when CI's commit, the one naming the new image, gets its check. Running a separate branch that only CI writes to would avoid this, at the cost of one more moving part.

### A promotion can conflict with edits near the image

On `main`, CI rewrites `image:` in `values-production.yaml` on every promotion, and `staging` never receives those commits. An edit on `staging` right next to that line (here, the comment above it) conflicts the next time `staging` is merged into `main`. Merge `main` into `staging` and keep `main`'s image, which the promotion overwrites anyway. Keeping the line CI owns away from what people edit, or in a file of its own, avoids the conflict altogether.

### Commits from CI don't trigger CI

The service's CI commits the new image to its own repository. Commits pushed with the workflow's built-in token don't start new workflow runs, which is what keeps that from looping.

### A push that changes a workflow needs a credential allowed to

GitHub refuses a push that creates or changes anything under `.github/workflows/` unless the credential behind it may change workflows: "refusing to allow an OAuth App to create or update workflow ... without `workflow` scope". A token that pushes everything else can still be refused. An SSH key is allowed, and so is a token with the `workflow` scope. Changing the platform's workflows takes one of them, and so does pushing the commit `just use-fork` makes, since it rewrites the platform repository the workflows services call check out.

## Tools around the platform

### The argocd CLI and Traefik

Before logging in, `argocd login` probes the server for TLS. Traefik answers that probe with its default certificate, even on port 80, and the CLI then stops to ask whether to proceed. `just argocd-login` skips the probe (`--skip-test-tls`), and `ARGOCD_OPTS` in `mise.toml` sets `--grpc-web --plaintext` for every command.

`just argocd-login <user>` names the CLI's context after the user. To switch, log in again: `argocd context <name>` writes a file under `~/.config/argocd`, outside the lab's own config, and fails.

### Traefik's chart warns about CRDs it doesn't ship

Installing Traefik prints a deprecation notice from its chart: the Gateway API CRDs will no longer be shipped, and it names a version older than the one running here. The chart ships none of them already, `helm show crds` lists only `traefik.io` and `hub.traefik.io`, and `scripts/base.sh` installs the Gateway API itself, at the version Traefik is built against. That step keeps the chart's output to itself unless it fails, so the notice only shows when you run the `helm upgrade` by hand.

### Crossview reads some things differently from kubectl

Crossview's own table still counts composed resources the old way, so that one column reads zero while the panel beside it lists them. Three more things look wrong before anything is. The Composite Resources table has no namespace column, so hello's two Buckets read as the same row twice. The Managed Resources count includes the provider's own `ClusterProviderConfig`, which sits in Crossplane's category without being a managed resource, so it says four where `kubectl get managed -A` says three. And a composed Secret opens with an empty summary instead of saying the read was refused, which is the lab's narrow role for Crossview doing its job ([why](decisions.md#crossview-as-the-window-into-crossplane-rather-than-komoplane)).
