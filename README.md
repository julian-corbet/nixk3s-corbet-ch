# nixk3s

**Bare-metal k3s on NixOS with a fully declarative GitOps spine: nixidy
renders, Argo CD reconciles, the host is a flake.**

The cluster foundation of an interoperating project set: one NixOS host (or a
few) running k3s, with every workload defined in Nix, rendered to plain
manifests by [nixidy](https://github.com/arnarg/nixidy), and synced by Argo CD
with prune + self-heal. No hand-applied YAML, no helm-on-the-CLI, no drift.

## The pitch

Running k3s on NixOS is easy. Running it *declaratively end-to-end* — host
config, cluster bootstrap, workload manifests, image delivery, tenancy — is a
pile of decisions everyone makes alone. `nixk3s` packages one coherent,
production-lived answer:

- **The host is a flake.** k3s server config, node labels, storage paths —
  all NixOS options, all reproducible.
- **Workloads are Nix too.** nixidy renders typed Nix modules to a plain
  manifest tree; Argo CD (prune + selfHeal) reconciles the cluster to git.
  The rendered tree is a build artifact you can read, diff, and audit.
- **Airgapped images.** Custom images are imported declaratively on the host
  (`services.k3s.images`) — no registry required for cluster-internal pieces.
- **Tenancy by AppProject.** A small, opinionated project model separating
  the things that *manage* the cluster from the things that *run on* it.

## What ships

- **`k3s-host`** (`nixosModules.k3s-host`, landed) — the NixOS side: k3s
  server with sane bare-metal defaults, declarative node labels, airgap image
  import.
- **`tenancy`** (`nixidyModules.tenancy`, landed) — the AppProject tenancy
  model and its allowed-destination conventions.
- **[docs/SPINE.md](docs/SPINE.md)** (landed) — the GitOps spine pattern:
  nixidy render → commit → Argo CD sync, with the rendered tree excluded from
  the render trigger (no loops).

## Status

**Pre-alpha, fully dogfooded.** The spine is real: it runs a production
single-node cluster (15+ Argo applications, GPU workloads, the whole works)
and has survived node rebuilds and a bare-metal migration — and since
2026-07-22 that cluster runs BOTH modules from this repo: its k3s server
config comes from `k3s-host`, and its entire Argo CD project layer (11
AppProjects + 5 protected namespace anchors) is rendered by `tenancy`,
adopted in-place with a semantically-verified zero-drift cutover (the
module + consumer values reproduced the live objects field-exactly).

## Related projects

- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — priority-based
  single-GPU sharing built on this spine.
- [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — the shared
  LLM serving lane running on that substrate.
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — curated
  nixidy app modules that deploy onto it.
- [nixvibe](https://github.com/julian-corbet/nixvibe-corbet-ch) — a coding
  agent in a real browser terminal, deployed onto this spine.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
