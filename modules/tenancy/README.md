# `nixk3s.tenancy`

Renders the Argo CD **AppProject** tenancy model as one nixidy Application,
synced at a low sync-wave so every project exists before the workload
Applications that reference it. AppProjects are Argo CD's namespace-boundary
mechanism: each project whitelists the namespaces its Applications may
deploy into, plus (optionally) which API groups/kinds and which source repos.

**The lesson this module encodes:** an Application whose target namespace is
missing from its AppProject's `destinationNamespaces` does not degrade
gracefully — Argo CD refuses the whole spec with `InvalidSpecError`, even for
resources that already exist and are otherwise healthy. The namespace has to
be in the project's allow-list before (or in the same render as) the app that
uses it.

## The default tenancy model

Ships three tiers, generic on purpose — the namespace lists are **empty by
default** (that's operator-specific data only a consumer has):

| Tier | For | Never |
|---|---|---|
| `management` | Manages the cluster/substrate itself — the platform, its cockpit, the shared-hardware device plugins/schedulers | Consumes the cluster as a tenant |
| `advanced` | Direct consumers of scarce shared hardware — pods that actually hold/burn a GPU (or similar), and the tier that serves it to everyone else | Merely *calling* a shared service |
| `apps` | Everything else, including apps that consume shared hardware only indirectly, via an HTTP/gRPC call to a service in `advanced` | Scheduling directly onto the scarce hardware |

### Sorting rule for GPU-era apps

This is the rule of thumb the three tiers exist to express, generalized from
a production single-GPU cluster:

- **Manages the card** (device plugin, GPU scheduler/priority classes) →
  `management`
- **Burns it directly** (a pod that actually gets scheduled onto the GPU, or
  the shared serving front door that does) → `advanced`
- **Uses it via a service** (calls a shared GPU-backed API, never itself
  touches the device) → `apps`

Add, rename, or split tiers freely — `projects` is a plain `attrsOf`, not
a fixed enum, and the three shipped tiers are CONFIG-side `lib.mkDefault`
definitions: your own definitions merge attr-by-attr with them (add a
project = add an attr; override a tier's description = redefine it). The
three tiers are therefore always present while the module is enabled — a
cluster that genuinely wants a different model replaces it wholesale with
`lib.mkForce`.

## Options

| Name | Type | Default | Description |
|---|---|---|---|
| `nixk3s.tenancy.enable` | bool | `false` | Enable the module. |
| `nixk3s.tenancy.argoNamespace` | str | `"argocd"` | Namespace Argo CD and its AppProject CRs live in. |
| `nixk3s.tenancy.destinationServer` | str | `"https://kubernetes.default.svc"` | `server` field on every generated destination entry. |
| `nixk3s.tenancy.appName` | str | `"projects"` | Name of the nixidy Application carrying the rendered AppProjects (and any anchored Namespaces). Override to adopt an existing application name in-place — same pattern as `nixllm.serving.appName`. |
| `nixk3s.tenancy.syncWave` | str | `"-2"` | `argocd.argoproj.io/sync-wave` on the projects Application — must land before wave-0 workloads. Orders the whole tenancy Application in the app-of-apps; anchored Namespaces need no annotation of their own (same-Application rendering orders them — the optional per-namespace `syncWave` exists only for intra-Application ordering). |
| `nixk3s.tenancy.projects` | attrsOf project | three tiers via config-side `mkDefault` (see above) | The tenancy model. Each project has `description`, `destinationNamespaces` (empty by default), `sourceRepos` (default `["*"]`), `clusterResourceWhitelist`/`namespaceResourceWhitelist` (default `[{group="*"; kind="*";}]`, i.e. permissive — see below), and `namespaces` (attrsOf namespace, empty by default — see "Anchoring namespaces" below). |
| `nixk3s.tenancy.projects.<name>.namespaces.<ns>.protected` | bool | `true` | Sets `argocd.argoproj.io/sync-options: Prune=false` on the generated Namespace object. |
| `nixk3s.tenancy.projects.<name>.namespaces.<ns>.labels` | attrsOf str | `{}` | Extra labels on the generated Namespace object. |
| `nixk3s.tenancy.projects.<name>.namespaces.<ns>.syncWave` | null or str | `null` | Optional INTRA-Application sync-wave (relative to sibling resources in the tenancy app only); `null` stamps nothing, matching the source system. |
| `nixk3s.tenancy.projects.<name>.namespaces.<ns>.annotations` | attrsOf str | `{}` | Extra annotations on the generated Namespace object (merged alongside the automatic sync-wave and `Prune=false` annotations). |

### Why the whitelists default to permissive

`clusterResourceWhitelist`/`namespaceResourceWhitelist` default to `*/*`. This
is a deliberate choice inherited from the source system: on a
single-operator cluster, the governance value of an AppProject is the
**namespace boundary** and the tier organization, not fine-grained resource
gating — the latter mostly adds "the project silently blocks an otherwise
fine sync" failure modes without a matching security win when there's only
one operator. A cluster with multiple mutually-distrusting tenants should
tighten these per project.

## Namespaces: mostly out of scope, except when you anchor one

This module still never creates the namespaces it lists in
`destinationNamespaces` **by default**. For most namespaces that remains the
right call: creation is left to whichever workload Application first targets
it via its own `createNamespace` (on `applications.<app>`).

The exception is `projects.<name>.namespaces`: an attrset of namespaces that
project explicitly **anchors** — rendered as real `Namespace` objects by this
same tenancy Application, at the same sync-wave as the AppProjects. Anchor a
namespace here only when the default ordering (created lazily by whichever
app gets there first) isn't good enough — typically because something else
(a SealedSecret, a ConfigMap) has to land in the namespace *before* the
wave-0 workload app's very first sync, or because the namespace needs to be
protected independent of whichever app(s) eventually target it.

**Why `protected` defaults to `true`:** this is the hard-won operational
lesson the whole feature exists to encode. Without the Argo sync-option
`Prune=false`, a manifest slip (a renamed/removed resource somewhere in the
rendered tree) can make Argo CD read the Namespace itself as
no-longer-desired and cascade-delete it — and everything running inside it —
instead of just the one resource that actually should have gone away. Every
namespace the source system ever anchored this way needed that guard, so the
option follows suit and defaults on; set `protected = false` per-namespace
only when you are confident a delete-and-recreate of that namespace is safe.

Every anchored namespace also gets `argocd.argoproj.io/sync-wave` set to the
same value as `nixk3s.tenancy.syncWave`, so it lands in the same wave as the
AppProjects rather than drifting to whatever wave Argo would otherwise infer.

## Minimal consumer example

```nix
{
  nixk3s.tenancy = {
    enable = true;
    projects.management.destinationNamespaces = [ "monitoring" "argocd" ];
    projects.advanced.destinationNamespaces = [ "llm" "gpu-workload" ];
    projects.apps.destinationNamespaces = [ "apps" ];

    # A cluster-specific tier the default model doesn't have:
    projects.data = {
      description = "Stateful data tier — database engines and their operators.";
      destinationNamespaces = [ "dbs" ];

      # Anchor "dbs" here (rather than leaving it to some workload app's
      # createNamespace) because a SealedSecret needs to land in it before
      # any wave-0 database Application syncs. protected defaults to true,
      # so this stateful namespace is also guarded against cascade-delete.
      namespaces.dbs = { };
    };
  };
}
```

Import the module into a nixidy env's `modules` list alongside the workload
Applications that reference these projects by name (`project = "advanced";`
etc. on `applications.<app>`).

## Status

Extracted from a production single-node k3s cluster's Argo CD project layer
(originally a static multi-document YAML file rendered as one Application at
sync-wave `-2`; this module reproduces that shape from typed options instead
and generalizes the tier names). This generalized form has been running live
there since 2026-07-22 — 11 AppProjects and 5 protected namespace anchors,
adopted in-place with a semantically-verified zero-drift cutover (the module
plus consumer values reproduced the live objects field-exactly; see the repo
README's Status section for detail).

## Source lineage

Generalized from a production single-GPU k3s cluster's Argo CD tenancy layer.
