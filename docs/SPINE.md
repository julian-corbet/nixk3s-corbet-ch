# The spine: render → commit → sync

`nixk3s` wires Kubernetes workloads the same way it wires the host: as Nix
that gets *rendered* to a plain artifact, which something else then
reconciles. For the host that something-else is `nixos-rebuild`; for the
cluster it's Argo CD. This document is the mechanism, independent of any
particular CI product.

## The three stages

```
   Nix modules              plain manifests            live cluster state
  (kubernetes/<env>/)  ──►  (a committed tree)   ──►   (Argo CD reconciles)
        nixidy render            git push                 Argo CD sync
```

1. **Render.** [nixidy](https://github.com/arnarg/nixidy) evaluates a set of
   typed Nix modules — the same NixOS-style `options`/`config` shape as
   everything else in this repo — into a tree of plain Kubernetes YAML. Helm
   releases get pre-rendered to static manifests in the same pass; nothing
   templated survives into the output.
2. **Commit.** The rendered tree is **not** a build cache or a `.gitignore`d
   scratch dir — it is committed to the repository like any other source
   file. That's deliberate: the rendered tree is a build artifact you can
   `git diff`, review in a PR, and audit years later without re-running
   nixidy or trusting anyone's local Nix evaluation.
3. **Sync.** Argo CD's Application(s) point at the rendered path in git —
   not at the Nix source, not at nixidy — with `prune` and `selfHeal` on.
   Argo has no idea nixidy exists; it just watches a git path and
   reconciles the cluster to whatever is there.

Because stage 3 only ever looks at the committed rendered tree, stages 1–2
can run anywhere that can evaluate Nix and push to the repo: a laptop, a
one-off CI job, a scheduled job on cluster-adjacent compute — the producer
doesn't matter, and this repo does not prescribe one. What matters is that
*something* keeps the rendered tree caught up with the Nix source and pushes
the result.

## nixidy env wiring (`mkEnvs`)

Each nixidy "environment" is a named set of Nix modules that get rendered
together into one output tree. A consumer flake declares them under a
`nixidyEnvs` output, using nixidy's `mkEnvs` helper:

```nix
{
  inputs.nixidy.url = "github:arnarg/nixidy";

  outputs = { self, nixpkgs, nixidy, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixidyEnvs.${system} = nixidy.lib.mkEnvs {
        inherit pkgs;
        envs = {
          # <env-name> is a placeholder — name it after the cluster/env
          # this module set renders for (a repo may define more than one).
          "<env-name>".modules = [
            ./kubernetes/<env-name>/tenancy.nix   # nixk3s.tenancy — AppProjects first
            ./kubernetes/<env-name>/storage.nix
            ./kubernetes/<env-name>/some-app.nix
            # one module file per concern; order mostly doesn't matter except
            # that the tenancy/projects module should render before anything
            # that references a project by name (see sync-wave below).
          ];
        };
      };

      # exposes `nix run .#nixidy -- build .#<env-name>` /
      # `nix run .#nixidy -- switch .#<env-name>` via the nixidy CLI package.
      packages.${system}.nixidy = nixidy.packages.${system}.default;
    };
}
```

`nix run .#nixidy -- build .#<env-name>` renders that env's modules to a
plain manifest tree (conventionally `gitops/rendered/<env-name>/`, but the
path is a convention, not something nixidy hardcodes); `switch` does the same
render and additionally applies it directly, which is useful for a local
dry-run but is not how the cluster itself gets updated (that's Argo, from
the committed tree — see below).

## The rendered tree is the thing Argo watches

Argo CD's Application(s) for the cluster point their `source.path` at the
rendered tree in this repo (e.g. `gitops/rendered/<env-name>/apps`, with an
app-of-apps pattern so each rendered sub-directory becomes its own
Application). Both `syncPolicy.automated.prune` and `.selfHeal` are on:
anything in the cluster that isn't in the rendered tree gets deleted, and
anything that drifts from it gets reverted — the rendered tree in git *is*
the cluster's desired state, full stop.

**This has a useful fallback property.** Because Argo reconciles from the
committed rendered tree directly — it has no dependency on nixidy, Nix, or
whatever renders the tree — a hand edit committed straight into the rendered
manifests still gets picked up and synced normally. That's a real emergency
valve when the render pipeline itself is down: you can patch the rendered
YAML directly, push, and Argo converges on it exactly as it would a normal
render. The tradeoff is exactly the one you'd expect: the next successful
render from the Nix source will overwrite that hand edit (the source of
truth for the *next* render is always the Nix modules, never the rendered
tree), so a hand edit is a stopgap, not a place to leave a permanent change.

## The one loop-prevention rule

Whatever renders the tree needs to react to changes in the Nix source
(`kubernetes/`, module directories, the flake lock, etc.) and push the
re-rendered tree back to the same repository. That push is itself a commit
to the repo — which means the render trigger's file-path filter **must
exclude the rendered output path**, or every render triggers another render,
forever:

```
trigger include:  [ "kubernetes/**", "modules/**", "lib/**", "flake.nix", "flake.lock" ]
                     # NOT "gitops/rendered/**" — that's the render's own output
```

This is the single load-bearing rule of the whole spine, and it generalizes
to any producer: a scheduled job, a git-hook, a person's pre-commit script —
whatever runs the render and pushes qualifies, as long as its trigger
condition is scoped to the Nix *source* paths and never to the rendered
*output* path. Get this backwards even once and the render step will push a
commit that re-triggers itself indefinitely.

A render is expected to be a deterministic function of (source, lockfile):
same inputs in, byte-identical tree out. That determinism is what makes a
"re-render on every relevant push" trigger safe to run unattended at all —
when the source hasn't actually changed in a way that affects the output,
the render step's own push is a no-op (nothing to commit), so the failure
mode above only bites if the path filter itself is wrong, not from ordinary
operation.

## Status

Extracted from a production single-node k3s cluster's render/commit/sync
pipeline (nixidy + a committed `gitops/rendered/` tree + Argo CD
prune+selfHeal), which has run through node rebuilds and a bare-metal
migration. This generalized description has not yet been re-verified against
a from-scratch consumer of this repo — treat it as a starting point, not a
tested artifact.
