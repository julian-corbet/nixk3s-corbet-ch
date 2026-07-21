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
default** (that's fleet-specific data only a consumer has):

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

Add, rename, split, or drop tiers freely — `projects` is a plain
`attrsOf`, not a fixed enum. A cluster with no GPU workloads at all can
delete `advanced` outright; one with several scarce resources might want a
tier per resource.

## Options

| Name | Type | Default | Description |
|---|---|---|---|
| `nixk3s.tenancy.enable` | bool | `false` | Enable the module. |
| `nixk3s.tenancy.argoNamespace` | str | `"argocd"` | Namespace Argo CD and its AppProject CRs live in. |
| `nixk3s.tenancy.destinationServer` | str | `"https://kubernetes.default.svc"` | `server` field on every generated destination entry. |
| `nixk3s.tenancy.applicationName` | str | `"projects"` | Name of the nixidy Application carrying the rendered AppProjects. |
| `nixk3s.tenancy.syncWave` | str | `"-2"` | `argocd.argoproj.io/sync-wave` on the projects Application — must land before wave-0 workloads. |
| `nixk3s.tenancy.projects` | attrsOf project | three-tier default (see above) | The tenancy model. Each project has `description`, `destinationNamespaces` (empty by default), `sourceRepos` (default `["*"]`), `clusterResourceWhitelist`/`namespaceResourceWhitelist` (default `[{group="*"; kind="*";}]`, i.e. permissive — see below). |

### Why the whitelists default to permissive

`clusterResourceWhitelist`/`namespaceResourceWhitelist` default to `*/*`. This
is a deliberate choice inherited from the source system: on a
single-operator cluster, the governance value of an AppProject is the
**namespace boundary** and the tier organization, not fine-grained resource
gating — the latter mostly adds "the project silently blocks an otherwise
fine sync" failure modes without a matching security win when there's only
one operator. A cluster with multiple mutually-distrusting tenants should
tighten these per project.

## Out of scope: namespaces

This module renders AppProjects only — it never creates the namespaces it
lists in `destinationNamespaces`. Namespace creation is left to the
consuming app's own `createNamespace` (on `applications.<app>`), or to a
companion module if a consumer wants namespaces managed as their own
resources.

One rule matters wherever that namespace creation ends up living: any
data-bearing namespace anchored at the `projects` sync-wave should carry the
Argo sync-option `Prune=false`. This is a hard-won operational lesson from
the source system — without it, a manifest slip (a renamed/removed resource
in the rendered tree) can cascade into Argo deleting a live, stateful
namespace along with everything in it, instead of just the one resource that
actually should have gone away.

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
and generalizes the tier names). This generalized form has not yet been
re-verified live — treat it as a starting point, not a tested artifact.

## Source lineage

Generalized from a production single-GPU k3s cluster's Argo CD tenancy layer.
