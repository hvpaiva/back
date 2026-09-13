# Decisions

Why the lab is built the way it is. Most of these trade realism for something that runs on one
laptop, and where the trade changes the answer, the entry says what a platform serving a company
would do instead.

## Cluster and base layer

- One kind node. Enough for the whole lab, and the lightest option. A company would keep the platform's own components away from the workloads, on separate node pools or separate clusters, and would run Argo CD from outside the cluster it deploys to. One node hides all of that, along with everything that makes a platform highly available.
- Kubernetes 1.35, not kind's default 1.37. A release Argo CD, Crossplane and Kyverno have had months to support.
- Traefik as the ingress controller. It serves Ingress and Gateway API at the same time, so the platform can move services from one to the other without touching the cluster. ingress-nginx, the usual choice, reached end of life in March 2026.
- Gateway API CRDs v1.6.1, installed before Traefik. The version Traefik 3.7 is built against; its chart doesn't ship them.
- LocalStack 4.14.0, pinned by digest. The Community edition ended in March 2026: newer images need an account and an auth token, and the free plan is for non-commercial use only. 4.14.0 is the last Community release. It runs without a token, but it gets no updates or security patches, and it never included RDS. Its state lives in memory. A company would give each stage its own cloud account, with credentials the platform holds and the teams never see; here one emulator serves every namespace with the same dummy key.
- Base layer installed by `just`, everything else by Argo CD. The base layer stands for what an infrastructure team provides. Everything a platform team would own is in Git.

## Delivery

- Argo CD installed once, then managing itself. The first install is the only step that isn't GitOps.
- Deploy configuration lives in the service's repository, one branch per stage. It keeps what a service needs next to its code, and it's the model teams are likely to meet in practice. The alternative, a separate repository with a folder per environment, makes promotion a one-line change in one place, at the cost of a second repository for every change.
- The running version is in Git. CI commits the image it built instead of telling Argo CD about it through its API. Git then always says what runs where, rollback is a revert, a rebuilt cluster comes back with the same versions, and CI needs no access to the cluster. The cost is a commit from CI on every deploy.
- Production runs the image staging ran. Promotion copies the image; it doesn't rebuild from `main`.
- Deploy feedback comes from Argo CD, not from CI. CI is done once it commits the image; Argo CD tells GitHub when that version is running and healthy, through a GitHub App, so CI still needs no access to the cluster.
- The platform maintains the services' CI too: checks per language (`go.yaml` for now) and one delivery workflow for all. Services call them at `main`, the same trade-off as the chart: a fix reaches every service at once, and so does a mistake. A service that needs stability can pin a commit instead.
- One ApplicationSet for every service, and onboarding one is an entry in its list: a repository, a branch, and the stage that branch deploys. The cost is the blast radius: one unreadable values file stops the generator for every service.
- A Helm chart as the golden path. Helm is how many teams already package their services. Here the platform maintains one chart, and each service only declares what it needs, much like a CircleCI orb.
- A service restarts when the platform changes a Secret it handed it. `envFrom` is read once, at start, so a rotated password or a renamed bucket would reach new pods and never the running ones. Reloader watches the Secrets a pod references and rolls the Deployment when one changes. It stamps the pod template rather than adding an environment variable, which the service's Application would take back out on its next sync, and Argo CD leaves the stamp alone, because it compares the fields it applies rather than everything on the object.
- The platform provides the Dockerfile, one per language (`build/go.Dockerfile`). Services don't carry build details, and a base image or compiler update reaches all of them at once. A service with special needs can still pass its own.
- Services in public GitHub repositories on a personal account. Argo CD reads them without credentials, and no company system is involved. Private repositories would mean a deploy key or a GitHub App, and one more secret to keep out of Git.

## Crossplane

- Crossplane v2, with namespaced managed resources. What a service requests, and what that creates, lives in the service's namespace.
- A service requests infrastructure in the same values files as everything else (`bucket:`), and the platform's chart renders the request. It goes through the same pull request, validation and promotion, and staging and production get separate resources. The alternative, request files in a separate repository, gives shared infrastructure a home but splits what a service needs across two places.
- Argo CD never deletes a service's data on its own: the requests the chart renders are exempt from pruning and from deletion with their Application, and the APIs themselves aren't pruned either, since deleting an XRD deletes every request made through it. Removing any of them is an explicit operation.
- AWS providers built by crossplane-contrib. Upbound publishes the same providers, but only their latest version is free; contrib's builds are Apache 2.0 and every version stays available.
- Postgres in the cluster, run by CloudNativePG. LocalStack never included RDS, and the operator handles what a managed database would: replicas, failover and credentials. What the lab leaves out is what a company would set up first: backups to object storage, and a restore someone has actually run.
- A bucket that exists keeps the name it was created with. The naming rule can change and new requests follow it, but S3 has no rename, so the Composition reports the name the bucket actually has instead of the one the rule would give it today.
- The Composition owns the name, S3's 63-character limit included: past it, the name is cut short and a hash of the full one keeps it unique. Deciding what a request may ask for in the first place is a different job, and it belongs where the cluster admits the request, not where the name is built.
- Only the resource types the platform uses are activated. The S3 provider alone ships 50, and each active one is a CRD the API server and Argo CD keep track of. With so few, the lab doesn't need the higher Argo CD API rate limit that Crossplane's Argo CD guide recommends.
- Every package pinned in Git, dependencies included. The family provider is declared rather than left to Crossplane's dependency resolution, which would install whatever version it finds.
- Compositions in Go templates (function-go-templating). They read like the Helm templates of the platform's chart.
- APIs no service uses yet. `Queue`, `Table` and `Cache` are there so the platform offers more than one kind of request, and each is implemented differently: two through a provider, one from plain Kubernetes objects. The chart renders only `Bucket` requests until the self-service templates settle how the others are asked for. A platform team wouldn't ship an API nobody asked for; these exist to show that one contract can sit on very different things.
- The cache's password is generated by its own Composition. Nothing else in the cluster generates one, so the Composition reads back the Secret it wrote and only mints a password when there is none. Deleting that Secret means a new password and a restarted server. A company would keep credentials out of the cluster's own manifests, in a secret manager the platform reads from, so that losing a Secret isn't the end of the story.

## Access

- Identities from client certificates the cluster's CA signs, not from an identity provider. A certificate names a user and its groups, the same things an identity provider's token carries, so RBAC is written the way a company would write it, without running Dex or logging kubectl in through a browser. The cost: a certificate can't be revoked before it expires, so they last 30 days, and `just up` issues new ones.
- Developers read; Git writes. `dev` can't change anything in the cluster: a change made there would skip the pull request, the validation and the promotion, and Argo CD would undo most of it anyway.
- A team's access comes with its services. The chart binds the team's group to the `developer` role in each namespace it deploys to, so nobody grants access by hand.
- Argo CD local accounts, with the built-in admin disabled, and passwords `just identities` generates and keeps in the cluster, not in Git. All services share one Argo CD project, so a developer sees other teams' services there, though not in kubectl. Separating teams in Argo CD takes a project per team.
- The `default` project closed. Every Application names the project whose rules it follows.

## Tooling

- just. Readable recipes, pinned by mise like the rest of the toolchain. Anything longer than a few lines lives in `scripts/`, so the justfile stays a list of what you can do.
- `setup.sh` in plain bash. It has to work before mise and just exist.
- The scripts stop at the first failure and say which command it was (`set -Eeuo pipefail` and an error trap in `scripts/lib.sh`). What's expected to fail says so where it happens, so the trap only ever reports a surprise. `setup.sh` is the exception and runs without `-e`: a checker that stops halfway hides everything it hasn't checked yet.
- `setup.sh` installs system packages on Ubuntu and Arch, and only checks on anything else. Nothing else in the repo depends on the system: mise pins the same toolchain everywhere, and everything the cluster runs is a container image. The `*.localhost` addresses need no setup on either, since systemd resolves them, through `systemd-resolved` on Ubuntu and `nss-myhostname` on Arch. On Arch the script never syncs or upgrades the package database: `pacman -Sy` on its own sets up a partial upgrade, and `-Syu` would upgrade the whole machine.
- An authoring loop that doesn't go through Git. Changing a Composition and pushing it to see what happens is a two-minute round trip. `just render <api>` runs the same functions Crossplane runs, here, in about a second, and checks the result against the schemas it has to satisfy. `just diff <app>` compares a folder on disk with what the cluster runs, the cheapest way to see what a push would do. `just render-service` covers the other thing a platform team changes all day, a service through the chart, for every stage at once; a chart change still reaches the cluster by push, because Argo CD syncs only single-source Applications from disk and a service's reads two repositories. `just local <app>` goes further and applies it, which means pausing Argo CD for that folder, and `just gitops` hands it back. Git stays the truth; the loop only admits that nobody writes a Composition right the first time.
- Each API ships an example request next to its Composition. It's what `just render` renders, and what to copy when asking for one by hand. The Application that delivers the APIs excludes those files, or it would create them in the cluster.
