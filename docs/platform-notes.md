# Platform notes

Things that aren't obvious until they bite, collected while building the lab. Each one is small; together they're most of the work of putting these tools together.

## Argo CD can't install itself

Something has to install Argo CD before it can manage anything. Here Helm installs it once (`just argocd`), and an Application in `platform/apps/argocd.yaml` then adopts that installation. Adoption only works if the Application renders exactly what Helm installed: same chart version, same release name, same values file. Get one of them wrong and Argo CD creates a second copy of itself next to the first.

The root Application has a bootstrap problem of its own: it creates the `platform` project, so it can't belong to it. It stays in the built-in `default` project, which allows everything, and that's why who may use `default` needs to be restricted once there are real users.

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

## Commits from CI don't trigger CI

The service's CI commits the new image to its own repository. Commits pushed with the workflow's built-in token don't start new workflow runs, which is what keeps that from looping.

## The argocd CLI and Traefik

Before logging in, `argocd login` probes the server for TLS. Traefik answers that probe with its default certificate, even on port 80, and the CLI then stops to ask whether to proceed. `just argocd-login` skips the probe (`--skip-test-tls`), and `ARGOCD_OPTS` in `mise.toml` sets `--grpc-web --plaintext` for every command.
