# Modules

Extraction targets, in order:

1. `k3s-host/` — NixOS module: k3s server defaults, declarative node labels,
   airgap image import, storage-path conventions
2. `gitops-spine/` — nixidy environment pattern + Argo CD bootstrap
3. `tenancy/` — the AppProject tenancy model
