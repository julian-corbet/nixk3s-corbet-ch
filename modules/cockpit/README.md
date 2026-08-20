# `nixk3s.cockpit`

**The platform's own faces**: the surfaces you open to find out whether the
cluster that runs your apps is working, declared here and rendered through the
app grammar.

```nix
{
  nixk3s.cockpit.surfaces.portal = {
    face = "homarr";
    version = "1.2.3";
    namespace = "the-namespace-you-keep-it-in";
    createNamespace = true;
    exposure = "nb";
    slot = 42;
    posixIdentity = { uid = 4242; gid = 4242; };
    state.appdata.hostPath = "/the/directory/that/already/holds/it";
    secrets.portal-secrets.env.SECRET_ENCRYPTION_KEY = "encryption-key";
    env.AUTH_PROVIDERS = "oidc";
  };
}
```

That renders an Argo CD Application, a Namespace, a Deployment that cannot roll
(the face keeps a single-writer database) and a ClusterIP Service — with the
port, the probes, the container-internal paths, the entrypoint's root-then-drop
behaviour and the reason the directory must already exist all coming from the
catalogue rather than from the declaration.

## Why a catalogue is allowed to exist here at all

This repository holds the mechanism. The app grammar renders whatever anybody
declares and deliberately knows nothing about *what kind of apps you have* — a
taxonomy of applications belongs to whoever ships the applications, and a
repository that grows one has started choosing which software its users may run.

Nothing in this module is an app you *have*.

> A face belongs in the catalogue only if it would still be worth running on a
> cluster with no apps in it.

Delete every workload in the cluster and this catalogue is unchanged and still
has a job: there is still a cluster, and it still has to be watchable. A
catalogue of "apps you have" is empty on that same cluster. That difference is
the whole boundary, and it is narrow on purpose:

| In | Out |
|---|---|
| The GitOps controller that syncs the tree | A wiki, however often a platform team reads it |
| The console you look at cluster objects through | A media server, a notes app, a dashboard somebody likes |
| The portal that is the front door to those surfaces | Anything whose purpose disappears when the cluster's apps do |

The right-hand column is not a lesser class of software. It is *cargo*, and
carrying it is the grammar's business — which stays incurious about what it
carries.

## Structurally separate, not separate by convention

The dependency runs one way and the code says so:

- The grammar does not import this module and cannot see it. This module
  imports the grammar, because a translator with nothing to translate into is
  not a module — so composing `nixidyModules.cockpit` alone is enough.
- `nixidyModules.default` carries the grammar and its interlocks and **not** the
  cockpit. Importing "everything" must not hand a consumer an opinion about
  which dashboards exist; taking a catalogue is its own deliberate line.
- `checks.tenancy-renders` composes the grammar *without* this module, so "a
  consumer can take the grammar without the cockpit" is checked rather than
  asserted. It would stop evaluating the day the grammar started needing a
  catalogue.

## A translator, not a renderer

This module defines into `nixk3s.apps` and renders no Kubernetes object of its
own. Everything expressible in the grammar's terms is expressed in them. What
it adds is the one thing the grammar cannot know: what a particular face *is*.

## The knowledge/value split, enforced rather than trusted

`lib/cockpit.nix` holds what is true of the software wherever anyone runs it.
A declaration holds what is true of one cluster. Neither may supply the other's
half, and that is an eval error rather than a convention:

| The catalogue knows | A declaration supplies |
|---|---|
| Which directories the face writes, and **where inside the container** | What backs each of them — an existing claim, or a path on a node |
| That a directory must already hold data, and why | Whether the backing is one that refuses to create it |
| That the image starts as root and drops privileges, and through which variables | Which uid and gid it drops to |
| Which variables name the container's own insides (its database, its cache, its fallback directory) | Everything else, merged over them |
| Which variables must arrive from a Secret | Which Secret, and which key inside it |
| How patient each probe has to be, and which probe is deliberately absent | — |
| The image repository | The version, or a whole digest-pinned reference |

Eleven guards keep the split honest. A directory the face does not write cannot
be backed, and one it does write cannot be left unbacked. A directory can carry
exactly one backing. A directory the catalogue marks as having to hold data
already cannot be backed by one that gets created — that failure is not a pod
that refuses to start, it is a healthy pod with none of your data in it, and the
refusal quotes the catalogue's own reason back. A variable that describes the
container's insides cannot be redefined, and neither can the two that carry the
identity. A value that must survive every restart unchanged must come from a
Secret, and writing it as a plain value is refused — everything rendered here is
committed. An image that drops privileges must be handed the identity it drops
to, and one that does not must not be handed one, because an identity nothing
reads is worse than none. Exactly one surface may anchor a namespace, one
position may be claimed by one surface, and a position claimed with no band
model in the render is refused by name.

Two mistakes **warn** rather than refuse, for the same reason in both cases —
what a cluster routes, and what sits in front of a face, are things one
deployment can see and this repository cannot: a surface that sleeps with no
wake front (nothing brings it back, and a cockpit you cannot open is worse than
one that is merely slow, because you reach for it exactly when something else is
wrong), and a surface exposed to the internet that selects no authentication
provider.

## Addressing

A surface may claim a `slot` — a position in the fleet's ordered identity space,
never an address. The band model's terms are handed over only when a surface
claims one, because `origin` and `slot` are options *that* module adds to the
grammar's apps: claiming a position without it in the render is refused by name
rather than failing on an option that does not exist. `origin` defaults to this
repository's own name, since this repository is the one declaring these
surfaces; a vendored copy declaring under another name says so.

## The catalogue

| Face | What it is |
|---|---|
| `homarr` | The portal: one page that is the front door to the platform's own surfaces. One container holding **both** its datastores — an in-process cache and an embedded SQLite database, no sidecar and no external server — which is exactly why it fits a grammar whose unit is one pod. The database is the constraint rather than the size: single-writer, so it cannot roll, cannot have a second replica and cannot share its directory. |

**One entry, deliberately.** Two more faces belong here by the same ownership
decision and neither is catalogued: one is the spine itself, bootstrapped before
any Application exists and declared through the app grammar nowhere yet, and the
other is still written in the older per-resource shape, so there is nothing to
translate. Room is left for both, and nothing about either is invented here — a
catalogue entry written from a guess is worse than a missing one, because the
missing one is visible.

## Status

Checked in both directions by `nix flake check`: `cockpit-eval` renders an
example surface and then feeds every guard a declaration that violates it, with
the *text* of each refusal asserted so a guard cannot pass by firing for an
unrelated reason; `cockpit-render` parses the manifests the module actually
produced and asserts them field by field, because a translator can resolve every
option correctly and still mount the wrong path or write a database onto the
pod's own filesystem.
