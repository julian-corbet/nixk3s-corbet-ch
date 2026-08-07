# `nixk3s.apps`

The **app grammar**: a shared vocabulary for declaring what an app *needs*,
from which this module renders the Argo CD Application, an optional Namespace,
a Deployment, and a Service.

Without a grammar, every workload module re-implements the same scaffolding —
an image, a port, a namespace, then a couple of hundred lines hand-building a
Deployment and a Service that differ from the next app's in about six places.
That repetition **is** the missing abstraction. Here the six differing places
are the only six things anyone writes:

```nix
{
  nixk3s.apps.paperless = {
    namespace = "documents";
    image = "ghcr.io/example/paperless:2.14.7@sha256:...";
    ports.http.number = 8000;
    exposure = "nb";
    scaling = "scale-to-zero";
    state.data = { claim = "paperless-data"; mountPath = "/usr/src/paperless/data"; };
    env.PAPERLESS_TIME_ZONE = "UTC";
    probe = { port = "http"; path = "/"; };
  };
}
```

That renders a Deployment (no replica count — the wake front owns it), a
ClusterIP Service targeting the named port, and an Argo CD Application in the
`apps` project that ignores `/spec/replicas`.

## An app is not a plane

There is no `cluster`, no `target`, no `host` option here, and there never will
be. An app sits *below* the cluster plane the same way a boot object sits below
a configuration plane: it does not name where it runs. It declares needs; which
cluster it lands in is a property of the render, not of the app.

## The public/private boundary

> An app declares NEEDS. Someone else allocates NUMBERS.

This is the rule that lets the vocabulary live in a public repository while the
clusters it renders for stay private. "I need a stable address" is a need; the
address is a fleet fact. "I need my state to survive a restart" is a need; which
storage backs it is a fleet fact.

So the option surface has no address, no slot, no octet, no UID/GID and no
storage path — not as discouraged fields, but as **absent** ones:

| Private fact | Why it cannot be written here |
|---|---|
| An address | `exposure` is a *class* (`internal`/`nb`/`public`). Services always render `ClusterIP`; no option reaches `loadBalancerIP`, `externalIPs` or `nodePort`. |
| A storage path | `state.<name>.claim` is the **name** of an existing claim. A value containing `/` fails eval — that is what a path looks like when someone smuggles one through a name field. There is no host-path option at all. |
| An address in free text | `image`, `env`, `command` and `args` are scanned for IPv4/IPv6 literals and rejected. Container-local addresses (`0.0.0.0`, loopback) are allowed, because those are facts about a container, not about a network. |
| Anything else | There is deliberately **no** escape hatch — no `extraPodSpec`, no raw manifest passthrough. One would re-open every row above. |

A private overlay that genuinely needs a private number sets it on the nixidy
resource directly (`applications.<app>.resources...` merges with what this
module renders), which keeps the private fact in the private repository instead
of in this vocabulary.

## The vocabulary

| Option | Type | Default | Meaning |
|---|---|---|---|
| `enable` | bool | `true` | Declaring the attribute is declaring the app; set false to park one. |
| `name` | str | attr name | Name of the app, its objects, and its Application. |
| `namespace` | str | attr name | Namespace it lands in. |
| `createNamespace` | bool | `false` | Create the namespace (always `Prune=false`; see below). |
| `project` | str | `appPlatform.defaultProject` | Argo CD AppProject. Interlocked with the tenancy model. |
| `image` | str | — | Container image. **Pin it by digest**; a tag-only image renders and warns. |
| `command` / `args` | list of str | `[ ]` | Entrypoint override and its arguments. |
| `env` | attrs of str | `{ }` | Plain environment. No secrets (the render is committed), no addresses (rejected). |
| `ports` | attrs of `{ number; protocol; }` | `{ }` | Named container ports. No ports ⇒ no Service. |
| `exposure` | `internal` \| `nb` \| `public` | `internal` | Who can reach it, as a class — never an address. |
| `scaling` | `always` \| `scale-to-zero` | `always` | Whether it idles at zero. |
| `wake` | `keda` \| `sablier` \| null | `null` | Which wake front. `null` resolves: `sablier` for GPU apps, `keda` otherwise. |
| `gpu` | bool | `false` | Claims the shared GPU: requests one device, and forces the `sablier` front when scaling to zero. |
| `replicas` | positive int | `1` | Replica count while running (`always` only). |
| `state` | attrs of `{ claim; mountPath; readOnly; }` | `{ }` | Persistent state, by claim **name**. Any state ⇒ `Recreate` strategy. |
| `probe` | `{ port; path; initialDelaySeconds; periodSeconds; }` or null | `null` | HTTP **readiness** probe. |

Cluster-wide facts the grammar needs, supplied once:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `nixk3s.appPlatform.defaultProject` | str | `"apps"` | Project an app lands in when it does not say. |
| `nixk3s.appPlatform.labelPrefix` | str | `"nixk3s.dev"` | Prefix for this grammar's own labels. |
| `nixk3s.appPlatform.gpuResourceName` | str or null | `null` | What your device plugin calls a GPU (`amd.com/gpu`, ...). Unset on purpose: a wrong guess schedules a GPU app with no device and no error, so `gpu = true` fails eval until it is named. |

## What it renders

- **Deployment** — labels carry the classification (`<prefix>/exposure`,
  `/scaling`, `/wake`, `/gpu`); the selector is name-only, because a selector is
  immutable and folding a mutable class into it would make a reclassification a
  delete-and-recreate. `Recreate` strategy when the app has state (a
  single-writer claim plus a rolling update is a deadlock). **No replica count
  at all** for a scale-to-zero app.
- **Service** — `ClusterIP`, one port per declared port, `targetPort` by name.
  Omitted entirely for an app with no ports.
- **Namespace** — only when `createNamespace`, always with `Prune=false`.
- **Application** — in the app's project, plus `ignoreDifferences` on
  `/spec/replicas` for a scale-to-zero app, so Argo CD and the wake front stop
  fighting over the field.

Only a *readiness* probe is synthesized, on purpose: it gates Service endpoints
and rollouts, which a grammar can get right. A synthesized **liveness** probe
cannot be — the same default that is merely conservative for a web app
restart-loops a slow-starting one forever.

## The two tenancy lessons, encoded

Both are inherited from [`tenancy`](../tenancy/README.md) and are enforced here
rather than documented here:

1. **An Application outside its project's destinations does not degrade
   gracefully** — Argo CD refuses the whole spec with `InvalidSpecError`, even
   for resources already healthy in that namespace. When the tenancy module is
   part of the same render, every app is checked against its project's
   `destinationNamespaces` and **fails eval** if it would be stranded. Rendering
   an app that cannot sync is worse than not rendering it.
2. **A namespace with live contents must carry `Prune=false`** — otherwise a
   manifest slip elsewhere in the tree makes Argo CD read the Namespace as
   no-longer-desired and cascade-delete everything inside it. Every namespace
   this grammar creates is stamped `Prune=false` explicitly, and **no option
   turns it off**. A second guard refuses two apps that both create the same
   namespace, because one Namespace with two Argo owners is the same footgun
   wearing a different hat.

## It fails closed

Every guard is checked in the failing direction by
`checks/apps-fail-closed.nix` — a guard nobody has seen fire is a comment.
Twelve declarations, each with exactly one thing wrong, must all be refused,
against a control declaration that must render:

```
control renders, and every guard fires:
  refused: address-literal-in-env
  refused: address-literal-in-image-registry
  refused: claim-that-is-really-a-path
  refused: exposed-with-nothing-to-expose
  refused: gpu-scale-to-zero-fronted-by-the-wrong-thing
  refused: ipv6-literal-in-env
  refused: namespace-created-by-two-apps
  refused: probe-on-an-undeclared-port
  refused: stranded-outside-project-destinations
  refused: targets-a-project-tenancy-never-defines
  refused: wake-front-on-an-always-on-app
  refused: gpu-without-a-named-device-resource
```

And `checks/apps-render.nix` asserts the other direction on the *rendered
manifests*, parsed with a YAML parser rather than trusted: a minimal app
renders both a Deployment and a Service, the selector matches the pod template
it selects, the Service targets a port the container declares, `exposure` and
`scaling` reach the objects, a scale-to-zero app carries no replica count while
its Application ignores that field, a portless app renders no Service, and a
created namespace carries `Prune=false`.

## Where domain repositories fit

This module is the vocabulary; it ships no apps. A domain repository (messaging,
media, sharing, ...) exports `nixidyModules` that consume it, so an app recipe
is a declaration rather than a hand-built manifest:

```nix
# nixdomain/apps/example/default.nix — a whole recipe
{ lib, config, ... }:
let cfg = config.nixdomain.example; in
{
  options.nixdomain.example.enable =
    lib.mkEnableOption "Example, the thing this domain repo ships";
  options.nixdomain.example.namespace = lib.mkOption {
    type = lib.types.str;
    description = "Namespace to deploy into.";
  };

  config = lib.mkIf cfg.enable {
    nixk3s.apps.example = {
      inherit (cfg) namespace;
      image = "ghcr.io/example/example:3.2.1@sha256:...";
      ports.http.number = 8080;
      exposure = "nb";
      state.config = { claim = "example-config"; mountPath = "/config"; };
    };
  };
}
```

The consumer's nixidy env imports both this grammar and the domain module; the
domain module knows the app, this module knows Kubernetes, and neither knows
anyone's addresses.

## Status

New. The vocabulary is extracted from a production single-node cluster's app
layer — which is what makes the option list this short: the fields are the ones
that actually differed between real apps, not the ones a Deployment schema
offers. Rendering is proven by `nix flake check`; unlike its sibling modules,
this one has not yet replaced a live app layer.
