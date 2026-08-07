# Modules

| Module | Class | What it is |
|---|---|---|
| [`k3s-host/`](k3s-host) | `nixosModules.k3s-host` | The NixOS side: k3s server defaults, declarative node labels, airgap image import, storage-path conventions. |
| [`tenancy/`](tenancy) | `nixidyModules.tenancy` | The Argo CD AppProject tenancy model and its allowed-destination conventions. |
| [`apps/`](apps) | `nixidyModules.apps` | The app grammar: apps declare what they NEED, this renders the Application, Namespace, Deployment and Service. |

The nixidy environment pattern and Argo CD bootstrap live in
[docs/SPINE.md](../docs/SPINE.md) as a document rather than a module — it is a
wiring pattern for a consumer's flake, not something to import.

`nixidyModules.default` carries `apps` + `tenancy` together: either works
alone, but importing both is what makes the destinations interlock checkable
(an app whose namespace is missing from its project's destinations fails eval
instead of failing to sync).
