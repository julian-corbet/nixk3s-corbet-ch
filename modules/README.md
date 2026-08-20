# Modules

| Module | Class | What it is |
|---|---|---|
| [`k3s-host/`](k3s-host) | `nixosModules.k3s-host` | The NixOS side: k3s server defaults, declarative node labels, airgap image import, storage-path conventions. |
| [`tenancy/`](tenancy) | `nixidyModules.tenancy` | The Argo CD AppProject tenancy model and its allowed-destination conventions. |
| [`apps/`](apps) | `nixidyModules.apps` | The app grammar: apps declare what they NEED, this renders the Application, Namespace, Deployment and Service. |
| [`addressing/`](addressing) | `nixidyModules.addressing` | The band model: a repository binds a band, its apps take slots inside it, and a slot outside it fails eval. |
| [`cockpit/`](cockpit) | `nixidyModules.cockpit` | The platform's own faces: a catalogue of the surfaces you open to see whether the platform is working, translated into the app grammar. |

The nixidy environment pattern and Argo CD bootstrap live in
[docs/SPINE.md](../docs/SPINE.md) as a document rather than a module — it is a
wiring pattern for a consumer's flake, not something to import.

`nixidyModules.default` carries the first three together: each works alone, but
importing them together is what makes the interlocks checkable — an app whose
namespace is missing from its project's destinations fails eval instead of
failing to sync, and an app whose slot is outside its repository's band fails
eval instead of colliding in every address space that number feeds.

**The cockpit is deliberately not in the default.** The other three are
mechanism and know nothing about what kind of apps you have; the cockpit is the
one catalogue of particular software here, and it is allowed to exist only
because nothing in it is an app you *have* — a face belongs there only if it
would still be worth running on a cluster with no apps in it. Importing
"everything" must not hand a consumer an opinion about which dashboards exist,
so taking it is its own line. The dependency runs one way: the cockpit imports
the grammar, the grammar cannot see the cockpit, and the check that renders the
grammar composes it without one.
