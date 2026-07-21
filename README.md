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

## Planned modules

- **`k3s-host`** — the NixOS side: k3s server with sane bare-metal defaults,
  declarative node labels, airgap image import, storage-path conventions.
- **`gitops-spine`** — the nixidy environment pattern + Argo CD bootstrap:
  render → commit → sync, with the rendered tree excluded from the render
  trigger (no loops).
- **`tenancy`** — the AppProject model and its allowed-destination
  conventions.

## Status

**Pre-alpha, extraction not started.** The spine is real: it runs a
production single-node cluster (15+ Argo applications, GPU workloads, the
whole works) and has survived node rebuilds and a bare-metal migration. This
repo will carry the generalized modules; nothing has been extracted yet.

## Related projects

- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — priority-based
  single-GPU sharing built on this spine.
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — curated
  nixidy app modules that deploy onto it.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
