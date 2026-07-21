# k3s-host

The NixOS side of a declarative bare-metal k3s node: a k3s server (or agent)
with sane defaults, declarative node labels rendered to `--node-label`
flags, airgapped image import so cluster-internal custom images need no
registry, and the small set of conventions the rest of the nixk3s GitOps
spine assumes.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `nixk3s.host.enable` | bool | `false` | Enable the module. |
| `nixk3s.host.role` | enum `"server"` \| `"agent"` | `"server"` | k3s node role. |
| `nixk3s.host.nodeLabels` | attrsOf str | `{ }` | Kubernetes node labels, rendered to `--node-label=<key>=<value>`. **Read the caveat below before relying on this.** The `gpu = "amd"` example is the cross-project convention this label follows so a node matches the sibling GPU-sharing substrate's default nodeSelector — see <https://nixgpu.corbet.ch>. |
| `nixk3s.host.airgapImages` | listOf package | `[ ]` | Container-image tarballs imported into k3s's airgap image dir (`services.k3s.images`) before k3s starts — no registry needed. |
| `nixk3s.host.disableComponents` | listOf str | `[ "traefik" "servicelb" "local-storage" ]` | k3s bundled components to turn off via `--disable=<name>`. **Server-only** — `--disable` is a k3s server flag, so this only renders into flags when `role = "server"`; it has no effect on an agent node. |
| `nixk3s.host.extraFlags` | listOf str | `[ ]` | Raw flags appended after the generated label/disable flags (CIDRs, TLS SANs, node name/IP pins, kubelet args, snapshotter choice, etc). |

## ⚠ Node labels only apply at first registration

k3s applies `--node-label` **once**, when a node first registers with the
cluster's datastore. On a node that is already a cluster member, changing
`nixk3s.host.nodeLabels` and running `nixos-rebuild switch` updates the
*declared* flag on disk but does **not** touch the live node object. The
label silently stays whatever it was before.

If you add, remove, or rename a label after a node's first boot, you must
also apply the change once, live:

```
kubectl label node <node-name> <key>=<value> --overwrite
```

Skip this step and nothing errors — every workload that selects on that
label (`nodeSelector`/affinity) just Pends forever, with no visible link
back to this option. This module keeps the Nix option as the declarative
record of intent; it cannot make k3s re-apply it for you.

## Example

```nix
{
  imports = [ nixk3s.nixosModules.k3s-host ];

  nixk3s.host = {
    enable = true;
    role = "server";
    nodeLabels = {
      "gpu" = "amd";
    };
    extraFlags = [
      "--node-name=my-node"
      "--tls-san=my-node"
      "--kubelet-arg=max-pods=250"
    ];
    airgapImages = [ myCustomImage ];
  };
}
```

## Status

Extracted from a production single-node bare-metal k3s cluster; this
generalized form has not yet been re-verified live. The source system is a
single-node server; agent mode is provided for completeness and has not been
exercised against a real multi-node cluster.
