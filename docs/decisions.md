# Decisions

Why the lab is built the way it is. Most of these trade realism for something that runs on one laptop, and where the trade changes the answer, the entry says what a platform serving a company would do instead.

## Cluster and base layer

### One kind node

Enough for the whole lab, and the lightest option. A company would keep the platform's own components away from the workloads, on separate node pools or separate clusters, and would run Argo CD from outside the cluster it deploys to. One node hides all of that, along with everything that makes a platform highly available.

### Kubernetes 1.35, not kind's default 1.37

A release Argo CD, Crossplane and Kyverno have had months to support.

### Traefik as the ingress controller

It serves Ingress and Gateway API at the same time, so the platform can move services from one to the other without touching the cluster. ingress-nginx, the usual choice, reached end of life in March 2026.

### Gateway API CRDs v1.6.1, installed before Traefik

The version Traefik 3.7 is built against; its chart doesn't ship them.

### MiniStack as the cloud account, pinned by digest

LocalStack's Community edition ended in March 2026, so the lab ran 4.14.0, the last release that needs no account, and that image gets no updates or security patches ever again. MiniStack is MIT with no account at all and a fifth of the memory, and it answered every call the platform's APIs make: bucket with its tags, versioning, queue and table all reconciled on the first attempt, through the same S3 Control DNS rule the previous emulator needed. The bet is its age. It was created the day after that sunset, and one author wrote most of it, though it ships a release every few days. The lab takes the bet because a laboratory is where you find out, and because the old image is pinned by digest and stays one revert away. MiniStack keeps its state in memory, like the old emulator. A company would give each stage its own cloud account, with credentials the platform holds and the teams never see; here one emulator serves every namespace with the same dummy key.

### Base layer installed by `just`, everything else by Argo CD

The base layer stands for what an infrastructure team provides. Everything a platform team would own is in Git.

## Delivery

### Argo CD installed once, then managing itself

The first install is the only step that isn't GitOps.

### Deploy configuration lives in the service's repository, one branch per stage

It keeps what a service needs next to its code, and it's the model teams are likely to meet in practice. The alternative, a separate repository with a folder per environment, makes promotion a one-line change in one place, at the cost of a second repository for every change.

### The running version is in Git

CI commits the image it built instead of telling Argo CD about it through its API. Git then always says what runs where, rollback is a revert, a rebuilt cluster comes back with the same versions, and CI needs no access to the cluster. The cost is a commit from CI on every deploy.

### Production runs the image staging ran

Promotion copies the image; it doesn't rebuild from `main`.

### Deploy feedback comes from Argo CD, not from CI

CI is done once it commits the image; Argo CD tells GitHub when that version is running and healthy, through a GitHub App, so CI still needs no access to the cluster.

### The platform maintains the services' CI too

It provides checks per language (`service-go.yaml` for now) and one delivery workflow for all, `service-delivery.yaml`. Services call them at `main`, the same trade-off as the chart: a fix reaches every service at once, and so does a mistake. A service that needs stability can pin a commit instead. They share `.github/workflows/` with the platform's own CI, since GitHub calls a reusable workflow from no other folder, so their names carry the difference: `service-*.yaml` is what services call; `ci.yaml` and `lab.yaml` check the platform. A repository of their own would separate them further, at the cost of a third repository to fork, and of a change to the chart and the pipeline that validates it landing in two places.

### One ApplicationSet for every service

Onboarding a service is an entry in its list: a repository, a branch, and the stage that branch deploys. The cost is the blast radius: one unreadable values file stops the generator for every service ([how](platform-notes.md#one-broken-service-can-stop-them-all)).

### A Helm chart as the golden path

Helm is how many teams already package their services. Here the platform maintains one chart, and each service only declares what it needs, much like a CircleCI orb.

### A service restarts when the platform changes a Secret it handed it

`envFrom` is read once, at start, so a rotated password or a renamed bucket would reach new pods and never the running ones. Reloader watches the Secrets a pod references and, when one changes, stamps the pod template of the service's Rollout, so the change reaches the requests through the same canary as a new image. Its restart strategy would skip the canary, and leave a service with one replica without a ready pod for a moment. The stamp is an annotation rather than an environment variable, which the service's Application would take back out on its next sync, and Argo CD leaves it alone, because it compares the fields it applies rather than everything on the object. Reloader watches the services' namespaces by name instead of the whole cluster: watching everything would give it every Secret in the cluster, Argo CD's own among them, and the right to restart anything the platform runs. The cost is a list that has to grow when a service arrives, so `just check` compares it with the namespaces that hold requests and asks whether Reloader can read Secrets and restart Rollouts in each. What lets it act in a service's namespace is a RoleBinding that service's own chart renders, to a ClusterRole the platform ships with Reloader, so the grant exists exactly when the namespace does. Ordering Reloader after the services instead would tie the platform's own sync to every service's ([why](platform-notes.md#a-wave-orders-one-application-not-what-another-one-creates)).

### Which front door serves a service is the platform's to set, not the service's

Traefik serves Ingress and Gateway API at the same time, so `platform.route` in the ApplicationSet moves one stage at a time and a service's values mention neither; hello moved that way, staging first and production after it, and both stages run on routes now. A service that had to choose would be a service that has to be changed every time the platform migrates.

### What a service's sync replaces is removed last

The services' Applications sync with `PruneLast=true`. An object a change replaces, like the Ingress a route takes over from, is deleted only after everything else in the sync is healthy. The same move from an Ingress to a route lost about two tenths of a second of requests without it, and none with it ([measured](platform-notes.md#moving-a-service-between-front-doors-costs-a-gap-unless-the-old-one-goes-last)).

The price comes with a broken replacement. The old object keeps serving, but the sync waits for the replacement to fail, up to ten minutes, a workload's default progress deadline, and no other sync of that service starts until then, or until someone terminates the one that's waiting. A change that ships a new version and removes an object in the same sync waits the same way, for its whole canary ([measured](platform-notes.md#a-deploy-that-also-removes-something-waits-for-its-canary)).

### Argo Rollouts moves a canary's traffic on the service's route

Argo Rollouts runs canaries: the new version starts beside the old one and takes a growing share of the requests, until it takes them all or an analysis sends them back. It moves that share on the service's HTTPRoute, through the Gateway API plugin, rather than through Rollouts' own Traefik support, which would put a TraefikService, a kind only Traefik reads, between the route and the service. The controller holds the permissions the plugin needs on routes, and none of those the chart grants by default for nine other traffic providers.

The plugin reaches the controller through an init container that copies it out of the plugin's own image, pinned by digest. The other documented way, a URL in the controller's ConfigMap, names one architecture and has every start of the controller download a 78 MB binary from GitHub, and a controller that can't load its plugin doesn't start. The image is built for amd64 and arm64, is a 19 MB pull, and stays on the node.

The dashboard runs in the cluster at http://rollouts.localhost, read-only. It has no login, so whoever opens it sees the Rollouts of every namespace, and read-only keeps it from promoting or aborting one. The CLI can serve the same page from the machine, but with the kubeconfig's identity and listening on every address of the machine.

### Every new version reaches the requests through a canary

The chart renders a Rollout instead of a Deployment. Anything that changes the pods, a new image, a size or a Secret the platform rewrote, starts the new version beside the old one, which takes a fifth of the requests for half a minute, then half for another, then all of them. Argo Rollouts can also run a Rollout that points at an existing Deployment, which its docs present as a way to migrate; the chart would then render both objects for good. No step waits for a person, since promotion from staging to production is already a pull request. A service without a route, on an Ingress or not public, has no share of requests to move, so its canary adds pods beside the stable ones and the requests follow the pods: with one replica, half of them from the first step.

A service moved to the Rollout without losing a request, and going back to a Deployment drops some ([measured](platform-notes.md#going-back-from-a-rollout-to-a-deployment-drops-requests)).

### A canary is judged by the requests it fails

While the canary takes its share, Argo Rollouts asks Prometheus how those requests came back, and sends every request to the old version if more than one in twenty is a server error. The question is a `ClusterAnalysisTemplate` the platform owns: every service is judged the same way, nothing about it reaches a service's values, and the backend to look at is an argument, so the same question can be asked of a whole stage later.

The numbers come from Traefik, which already counts what it serves by backend and status code, so no service has to expose anything to have its canary judged. They exist only for a service on a route: on an Ingress a canary adds pods instead of moving requests, and Traefik counts one backend for both versions.

Two rules keep a deploy from stopping on nothing. A backend under half a request a second isn't judged, because one error out of three requests says nothing about a version, so a canary nobody calls goes through. And if Prometheus can't answer, the canary goes through too, with the error kept in the run: a check the platform can't make doesn't hold a version back ([measured](platform-notes.md#a-check-that-cant-answer-lets-a-canary-through)).

### The route's weights belong to Argo Rollouts

The services' Applications leave the route's weights out of what they compare, so a canary moving them doesn't turn an Application *OutOfSync*. A sync still writes the route as the chart renders it, though, and `RespectIgnoreDifferences`, the option meant to keep an ignored field's live value, doesn't keep these ([measured](platform-notes.md#a-sync-in-the-middle-of-a-canary-rewrites-the-routes-weights)). So the chart renders them as 100 for the stable version and 0 for the canary, and a rewrite sends every request to the stable version instead of half of them to the canary. The Applications also sync with `ApplyOutOfSyncOnly=true`, so a sync that changes something else doesn't rewrite the route at all.

### The platform provides the Dockerfile, one per language

`build/go.Dockerfile` is the one for Go. Services don't carry build details, and a base image or compiler update reaches all of them at once. A service with special needs can still pass its own.

### Services in public GitHub repositories on a personal account

Argo CD reads them without credentials, and no company system is involved. Private repositories would mean a deploy key or a GitHub App, and one more secret to keep out of Git.

## Crossplane

### Crossplane v2, with namespaced managed resources

What a service requests, and what that creates, lives in the service's namespace.

### A service requests infrastructure in its own values files

It asks with `bucket:` or `database:`, like everything else it needs, and the platform's chart renders the request. It goes through the same pull request, validation and promotion, and staging and production get separate resources. The alternative, request files in a separate repository, gives shared infrastructure a home but splits what a service needs across two places.

### A service's data outlives its request

Argo CD never deletes a request the chart renders, whether the request leaves the service's values or the service's Application goes, and never prunes the APIs, since deleting an XRD deletes every request made through it. Crossplane never deletes a bucket or a table: their Compositions leave Delete out of what the provider may do, so a request that goes, by hand or with its namespace, leaves its data in the cloud account, and the same request applied again adopts it instead of starting empty. A versioned bucket keeps its versions, but versioning itself goes with the request and stays suspended until the request comes back: removing it is also how a request that stops asking for versioning turns it off. Removing data is an explicit operation in the account itself, which `just reset` carries out for the requests nobody committed.

A database is protected another way, because its data lives in volumes CloudNativePG owns, where no policy of the provider reaches. The chart puts a Usage next to the request, so deleting the request by hand is refused with the Usage's reason, and Argo CD never deletes either of them. A namespace deleted with the database in it still takes its volumes along. What stays is its backups, in the cloud account, and the same request asking for a restore starts from them ([how](#every-database-is-backed-up-from-the-moment-it-exists)).

### AWS providers built by crossplane-contrib

Upbound publishes the same providers, but only their latest version is free; contrib's builds are Apache 2.0 and every version stays available.

### Postgres in the cluster, run by CloudNativePG

It's the lab's example of an API built on a third-party operator rather than on a cloud provider, and the operator handles what a managed database would: replicas, failover and credentials. The emulator has an RDS of its own, which the lab doesn't use and hasn't tested.

The Composition pins the Postgres image, so upgrading the operator doesn't move every database to a new Postgres on its own. It uses CloudNativePG's `standard` image rather than the `system` one the operator still defaults to. The `system` images are deprecated, and the `standard` ones leave out the Barman tools the operator's built-in backup runs: backups come from the Barman Cloud plugin instead, which brings those tools in a container of its own next to Postgres.

### A database's size can change later, its disk can't

A size sets how many instances run and how much memory each gets, and a service can move it up or down. It also sets the disk, but only when the database is created. From then on the Composition keeps the disk the cluster already has. No volume can shrink, and kind's storage class can't grow one: a database here that asked for a bigger disk stopped short of everything else it asked for, and still read as Ready ([what that looks like](platform-notes.md#a-database-that-cant-grow-its-disk-still-reads-healthy)). On storage that grows, a company would give the disk a field of its own that only goes up.

### Every database is backed up from the moment it exists

A `Database` asks for a `Bucket` of its own and keeps its backups there, so they follow a bucket's rules: they stay when the request goes, and the same request finds them again when it comes back. The Barman Cloud plugin sends every change to that bucket as it happens, takes a full backup as soon as archiving works and every night after that, and keeps seven days. A new database isn't created until its bucket is ready, and it reads as not ready while its archiving fails, so a database that isn't being backed up doesn't pass for a healthy one.

The plugin is what CloudNativePG offers now: the operator's built-in Barman support is deprecated since 1.26. It needs cert-manager for the certificates it and the operator talk over. A company would keep backups in another account, with versioning and object lock on the bucket, keep them longer and rehearse restores on a schedule. The lab's emulator keeps them in memory, so restarting it loses them.

### A restore is part of the request, read when the database is created

`restore: {}` starts a database from the latest point its backups reach, and `restore: {at: <time>}` from a moment in them. Like the disk, it counts only when the database is created: restoring a database that exists means deleting it, Usage first, and letting it come back with `restore`. The restored database goes on archiving into the folder it came from, on a new timeline, so the moments before the restore stay within reach. A database created empty where an earlier one left backups is refused archiving instead, and stays not ready until it's restored or those backups are removed.

### A name says whose a thing is and what it is, never what runs it

A request's name is the name of what it makes. The chart calls hello's requests `bucket` and `database`, and `name:` in a service's values picks another. In the cloud account, which every namespace shares, a name starts with the namespace, `<application>-<stage>-<name>`. Whatever a resource adds to its name goes after that, as CloudNativePG does with its Services and instances and SQS with `.fifo`, so the stage never lands in the middle of one. Inside the namespace, which already says whose it is, a name is the request's name and its kind, `orders-database`, or only the kind when that's what the request is called. A service reaches its database at a Service the platform names, `database.hello-staging.svc`, rather than at the one CloudNativePG creates, so running Postgres some other way wouldn't change the address.

A service picks the name, not the prefix. A request whose name is already taken in the cloud account adopts what's there, so a free name would let one service take over another's bucket.

### What exists keeps the name it was created with

The naming rule can change and new requests follow it, but S3, SQS and DynamoDB have no rename, and Crossplane doesn't rename what a Composition made either ([what it does instead](platform-notes.md#a-composition-cant-rename-what-it-made)). So each Composition reads the names its resources actually have and uses them instead of the ones the rule would give them today. A database whose cluster was created under an earlier rule keeps that cluster's name, and the key it's filed under.

### The Composition owns the name, and the limits that come with it

S3 stops a bucket's name at 63 characters, and CloudNativePG a cluster's at 50. Past a limit, the name is cut short and a hash of the full one keeps it unique. Deciding what a request may ask for in the first place is a different job, and it belongs where the cluster admits the request, not where the name is built.

### Only the resource types the platform uses are activated

The S3 provider alone ships 50, and each active one is a CRD the API server and Argo CD keep track of. With so few, the lab doesn't need the higher Argo CD API rate limit that Crossplane's Argo CD guide recommends.

### Every package pinned in Git, dependencies included

The family provider is declared rather than left to Crossplane's dependency resolution, which would install whatever version it finds.

### Compositions in Go templates (function-go-templating)

They read like the Helm templates of the platform's chart.

### APIs no service uses yet

`Queue`, `Table` and `Cache` are there so the platform offers more than one kind of request, and each is implemented differently: two through a provider, one from plain Kubernetes objects. The chart renders `Bucket` and `Database` requests, and the others wait until the self-service templates settle how they're asked for. A platform team wouldn't ship an API nobody asked for; these exist to show that one contract can sit on very different things.

### The cache's password is generated by its own Composition

Nothing else in the cluster generates one, so the Composition reads back the Secret it wrote and only mints a password when there is none. Deleting that Secret means a new password and a restarted server. A company would keep credentials out of the cluster's own manifests, in a secret manager the platform reads from, so that losing a Secret isn't the end of the story.

### Crossview as the window into Crossplane, rather than Komoplane

Komoplane is the better known of the two. Asked about the same request, Komoplane resolves none of the two resources it composed and Crossview both: v2 keeps them under `spec.crossplane.resourceRefs`, and Komoplane builds against a runtime that only knows the older `spec.resourceRefs`. Crossview reads either, has pages for kinds that exist only in v2, and ships releases; its Postgres is for user sessions, which a lab with no accounts doesn't need. Both charts ask to read every resource in the cluster, Secrets included, which is more than the lab gives Reloader, so the chart's role is off and the lab ships its own, named group by group and without Secrets. Asked the same twenty-three questions, the narrow one answers identically; only the composed Secret stops being readable, which was the point, since the UI has no login and handed its contents to whoever asked. The cost is a list that grows with each provider, and a group left out of it shortens the pages without an error anywhere, so `just check` compares the role with what the cluster serves. What Crossview shows differently from kubectl is in [platform notes](platform-notes.md#crossview-reads-some-things-differently-from-kubectl).

### StackPort as the window onto the cloud account, read-only

What the platform creates in the emulator was otherwise visible only from the CLI, and the emulator's own browser is a hosted web app: the data never leaves the machine, but it needs an account and an internet connection, which a lab anyone can clone shouldn't. StackPort is one image against any AWS-compatible endpoint, and the lab turns writing off, so the rule the platform teaches holds in the window too: Git writes, people read. `just check` fails if that flag ever comes back on. StackPort asks for 512Mi against a 1Gi limit because of what it holds: 68 to 72 MiB before it has served its own page, and 566 to 591 MiB once it has, which it never gives back. The node has to keep room for the second number, and that one-to-two ratio between request and limit is the one the chart gives every service size.

## Policy

### Kyverno installed before there is a policy to enforce

It registers its webhooks as soon as it starts, but the two that reach anything outside its own kinds stay empty until a policy exists, so the gate is in place and open. Every write in the cluster goes through it once a rule exists, which is a thing to have running and watched well before a rule depends on it.

### Rules in CEL, not `ClusterPolicy`

Kyverno 1.19 deprecated the original policy kinds and 1.20 removes them, and the CEL types reached parity in the same release, so what the platform writes here is `ValidatingPolicy` and its siblings in `policies.kyverno.io`.

### Kyverno's cleanup controller is off

It serves `CleanupPolicy` alone, and nothing in the lab deletes on a timer.

## Metrics

### Prometheus and its operator, without the rest of the stack

Prometheus reads what Traefik counts for every service it routes to: requests by status code, and how long they took. The platform can tell how any service is doing without the service exporting a metric of its own.

It comes from kube-prometheus-stack, for the Prometheus Operator: what to scrape is an object, a `PodMonitor` or a `ServiceMonitor`, and charts such as Argo CD's, Kyverno's and Traefik's can create their own. The rest of the stack is off, since nothing in the lab reads it and each piece costs memory on the one node: Grafana, Alertmanager, the node and kube-state metrics, and the chart's default alerting rules. Traefik comes with the base layer, outside Argo CD, so the monitor that reads it lives in `platform/prometheus/`.

Metrics are kept for ten days on the pod's own disk, and they go with the pod. A company would keep them longer, in storage that outlives a pod, with alerts routed to whoever owns each service.

## Access

### Identities from client certificates the cluster's CA signs, not from an identity provider

A certificate names a user and its groups, the same things an identity provider's token carries, so RBAC is written the way a company would write it, without running Dex or logging kubectl in through a browser. The cost: a certificate can't be revoked before it expires, so they last 30 days, and `just up` issues new ones.

### Developers read; Git writes

`dev` can't change anything in the cluster: a change made there would skip the pull request, the validation and the promotion, and Argo CD would undo most of it anyway.

### A team's access comes with its services

The chart binds the team's group to the `developer` role in each namespace it deploys to, so nobody grants access by hand.

### Argo CD local accounts, with the built-in admin disabled

`just identities` generates their passwords and keeps them in the cluster, not in Git. All services share one Argo CD project, so a developer sees other teams' services there, though not in kubectl. Separating teams in Argo CD takes a project per team ([more](platform-notes.md#argo-cd-has-permissions-of-its-own)).

### The `default` project closed

Every Application names the project whose rules it follows.

## Tooling

### just for the recipes

Its recipes read easily, and mise pins it like the rest of the toolchain. Anything longer than a few lines lives in `scripts/`, so the justfile stays a list of what you can do. Each step reports one line and keeps the tool's output for when it fails: the first run of `just up` is a dozen lines you can read instead of a page of server-side apply confirmations, and a failure shows everything that went with it. A slow step spins while it works, and `just up` opens by saying what it is about to do and roughly how long that takes. There's no progress bar: none of these steps has a total to measure against, so a bar would be decoration, and the honest numbers are the expected four minutes and the count of Applications still to become ready. Nothing is thrown away, either: the running step names the command behind it, and what that command printed is appended to `.logs/lab.log`, so a run that looked fine on screen can still be read line by line afterwards.

### `setup.sh` in plain bash

It has to work before mise and just exist.

### The scripts stop at the first failure and say which command it was

They run with `set -Eeuo pipefail` and an error trap in `scripts/lib.sh`. What's expected to fail says so where it happens, so the trap only ever reports a surprise. `setup.sh` is the exception and runs without `-e`: a checker that stops halfway hides everything it hasn't checked yet.

### `setup.sh` installs system packages on Ubuntu and Arch, and only checks on anything else

Nothing else in the repo depends on the system: mise pins the same toolchain everywhere, and everything the cluster runs is a container image. The `*.localhost` addresses need no setup on either, since systemd resolves them, through `systemd-resolved` where it runs and `nss-myhostname` where it doesn't. On Arch the script never syncs or upgrades the package database: `pacman -Sy` on its own sets up a partial upgrade, and `-Syu` would upgrade the whole machine.

### An authoring loop that doesn't go through Git

Changing a Composition and pushing it to see what happens is a two-minute round trip. `just render <api>` runs the same functions Crossplane runs, here, in about a second, and checks the result against the schemas it has to satisfy, the operators' included. A kind it has no schema for fails the check rather than passing it. With the lab running, it also puts the CRD the XRD becomes to the API server, the only place that refuses a CEL rule too costly to run ([how](platform-notes.md#an-xrd-the-api-server-refuses-shows-no-error)). `just diff <app>` compares a folder on disk with what the cluster runs, the cheapest way to see what a push would do. `just render-service` covers the other thing a platform team changes all day, a service through the chart, for every stage at once; a chart change still reaches the cluster by push ([why](platform-notes.md#a-local-sync-sees-one-source-only)). `just local <app>` goes further and applies the folder, which means pausing Argo CD for that folder, and `just gitops` hands it back. Git stays the truth; the loop only admits that nobody writes a Composition right the first time.

### Each API ships an example request next to its Composition

It's what `just render` renders, and what to copy when asking for one by hand. The Application that delivers the APIs excludes those files, or it would create them in the cluster ([how](platform-notes.md#an-application-applies-every-file-in-its-folder)).

### The platform's CI runs `just test`

Every check CI makes is a recipe first, so a failure on GitHub reads the same on a laptop, and the same command reproduces it. The jobs have no cluster, and `just test` needs none: the renders, their schemas and the health checks all work offline. What only an API server answers, like a ConfigMap key it refuses or a CEL rule too costly to run, gets asked whenever a cluster is there.

### One validator for everything the lab renders

`crossplane resource validate` checks core Kubernetes kinds as well as every CRD it's given, CEL rules included, with the API server's own validation library. The lab already ran it on its APIs, so it checks the chart's output and everything Argo CD applies too, instead of adding kubeconform, which needs every CRD converted to JSON Schema first and doesn't run CEL. Neither can see what only the API server refuses.

### Scenarios live in `tests/`, not next to the APIs

A Composition decides most of what it composes from what already exists, so a render against the example request alone leaves most of it out: the database's example renders two of its six resources ([why](platform-notes.md#a-render-sees-only-what-a-composition-makes-from-nothing)). A scenario hands the render what a cluster would already hold. They can't sit next to the Compositions, because the Application that delivers the APIs applies every file in their folders.

### The lab is built from nothing after a push that can change it, and every night

It's the only check where Crossplane, the operators and the cloud account actually do what the platform asks, and it keeps the README honest on a fresh Ubuntu 24.04 machine: a chart that moved or an image that vanished upstream shows up there before someone cloning the lab finds it. Argo CD reads the platform from `main`, in CI as anywhere, so this job says whether `main` works, not whether a pull request would.

A build takes about ten minutes, so a push that changes only docs, Dockerfiles or other workflows doesn't start one. Every other push does, even one that only edits comments in a script: a path filter sees which files changed, not what changed in them. The build is a workflow of its own, `lab.yaml`, so `ci.yaml`'s checks don't wait for it, and a newer push cancels a build still under way, which would run the newer platform anyway.
