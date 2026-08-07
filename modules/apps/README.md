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
    secrets.app.env.PAPERLESS_SECRET_KEY = "secret-key";
    env.PAPERLESS_TIME_ZONE = "UTC";
    probes.readiness = { port = "http"; path = "/"; failureThreshold = 12; };
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

> An app declares NEEDS. Someone else supplies the VALUES.

Options are parameters: this repository declares them, a private consumer sets
them — exactly the way `namespace` already works in every recipe ever written.
What must never happen is a fleet fact getting *baked in* to a public
declaration. Three kinds are structurally impossible to write at all:

| Private fact | Why it cannot be written here |
|---|---|
| An address | `exposure` is a *class* (`internal`/`nb`/`public`). Services always render `ClusterIP`; no option reaches `loadBalancerIP`, `externalIPs` or `nodePort`. |
| A path in a name field | `state.<n>.claim` and `secrets.<n>.secret` are **names** of existing objects. A value containing `/` fails eval — that is what a path looks like when someone smuggles one through a name field. |
| An address in free text | `image`, `env`, `command` and `args` are scanned for IPv4/IPv6 literals and rejected. Container-local addresses (`0.0.0.0`, loopback) are allowed, because those are facts about a container, not about a network. |

`state.<n>.hostPath` is the one term whose value is unavoidably a path, because
that is how most self-hosted apps are actually backed. It is a parameter like
any other: the public declaration takes it, the private consumer passes it in.

Secrets get the same treatment from the other side: an app names a Secret and
says how it consumes it, and nothing in this vocabulary can express a secret's
*content*. A declaration is therefore safe to publish even when the Secret it
names is not.

## Two ways out, both deliberate and both visible

An abstraction people route around is worse than one visible hatch — so there
are exactly two, ordered by preference:

1. **Typed merge (preferred).** Everything this module renders is an ordinary
   nixidy resource, so a private module can define *more fields* on the same
   objects and the module system merges them:

   ```nix
   # a module the consumer keeps private
   applications.example-web.resources = {
     services.example-web.spec.clusterIP = "10.0.0.9";        # a pinned address
     deployments.example-web.spec.template.spec = {
       enableServiceLinks = false;                             # a pod-spec knob
       securityContext = { runAsUser = 3001; runAsGroup = 3001; };  # an identity
     };
   };
   ```

   The app declaration stays free of fleet facts; the fleet facts stay in the
   repository that owns them. `checks/apps-render.nix` renders exactly this
   overlay and asserts both that the private fields land and that the grammar's
   own fields survive.

2. **`raw`** — YAML documents passed through for whole objects the grammar has
   no term for (a wake-front CR, a ConfigMap). No typed options, no schema
   defaults injected, no scanning. It is the one place the boundary stops being
   enforced, so it is kept **countable**: every app using it warns at render,
   and `nixk3s.appPlatform.rawEscapeHatchApps` lists them, so "how much of this
   cluster is still untyped" has a number that can be watched going down.

## The vocabulary

| Option | Type | Default | Meaning |
|---|---|---|---|
| `enable` | bool | `true` | Declaring the attribute is declaring the app; set false to park one. |
| `name` / `namespace` | str | attr name | Name of the app's objects; namespace it lands in. |
| `createNamespace` | bool | `false` | Create the namespace (always `Prune=false`; see below). |
| `project` | str | `appPlatform.defaultProject` | Argo CD AppProject. Interlocked with the tenancy model. |
| `image` | str | — | Container image. **Pin it by digest**; a tag-only image renders and warns. |
| `command` / `args` | list of str | `[ ]` | Entrypoint override and its arguments. |
| `env` | attrs of str | `{ }` | Plain environment. No secrets (the render is committed), no addresses (rejected). |
| `ports` | attrs of `{ number; protocol; }` | `{ }` | Named container ports. No ports ⇒ no Service. |
| `exposure` | `internal` \| `nb` \| `public` | `internal` | Who can reach it, as a class — never an address. |
| `scaling` | `always` \| `scale-to-zero` | `always` | Whether it idles at zero. |
| `wake` | `keda` \| `sablier` \| null | `null` | Which wake front. `null` resolves: `sablier` for GPU apps, `keda` otherwise. |
| `gpu` | bool | `false` | Claims the shared GPU: requests one device, forces the `sablier` front when scaling to zero. |
| `replicas` | positive int | `1` | Replica count while running (`always` only). |
| `resources.requests` / `.limits` | attrs of str | `{ }` | Compute. A GPU device request is added automatically when `gpu` is set. |
| `state` | attrs of `{ claim \| hostPath; hostPathType; mountPath; readOnly; }` | `{ }` | Persistent state — **one concept, two backings**. Any state ⇒ `Recreate`. |
| `secrets` | attrs of `{ secret; envFrom; env; mountPath; optional; }` | `{ }` | Secrets by name, plus how they are consumed. Never the content. |
| `probes.readiness` / `.liveness` / `.startup` | probe or null | `null` | `path = null` probes the TCP socket; otherwise HTTP GET. |
| `adopt` | bool | `false` | Server-side apply + diff, for taking over objects that already exist. |
| `raw` | list of str | `[ ]` | The escape hatch (above). |

Cluster-wide facts the grammar needs, supplied once:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `nixk3s.appPlatform.defaultProject` | str | `"apps"` | Project an app lands in when it does not say. |
| `nixk3s.appPlatform.labelPrefix` | str | `"nixk3s.dev"` | Prefix for this grammar's own labels. |
| `nixk3s.appPlatform.gpuResourceName` | str or null | `null` | What your device plugin calls a GPU. Unset on purpose: a wrong guess schedules a GPU app with no device and no error, so `gpu = true` fails eval until it is named. |
| `nixk3s.appPlatform.hostPathNodeSelector` | attrs of str | `{ }` | Node selector for apps with node-path state. Which node that is, is a fleet fact — set once, privately. |
| `nixk3s.appPlatform.rawEscapeHatchApps` | list of str | *(read-only)* | Apps still carrying verbatim manifests. |

### State: one concept, two backings

An app declares "I need persistent state"; the consumer decides how it is
backed. Exactly one backing per entry, and neither is created here — a volume
outlives the app, so its existence is not the app's to declare.

```nix
state.config = { claim = "example-config"; mountPath = "/config"; };     # a PVC, by name
state.data   = { hostPath = cfg.dataPath;  mountPath = "/data"; };       # a node path, parameterized
```

**hostPath pins the pod to a node.** The path only exists on the node that has
it, so the app can only ever run there. On a single-node cluster that is
invisible; the day a second node joins, the app either becomes unschedulable
elsewhere or — worse — starts there against an empty directory. So the grammar
says it out loud: every rendered object gets a `<prefix>/node-pinned` label, an
explicit `nodeSelector` appears when `appPlatform.hostPathNodeSelector` is set,
and an app that is pinned with nothing saying so warns until it is.

### Secrets: named, consumed, never carried

```nix
secrets.credentials.env.DB_PASSWORD = "db-password";   # one key -> one variable
secrets.oidc = { secret = "app-oidc"; envFrom = true; };  # every key -> the environment
secrets.certs = { secret = "app-certs"; mountPath = "/run/certs"; };  # keys as files
```

A reference that consumes nothing fails eval, because it is a typo rather than
a declaration. A variable defined both in `env` and from a Secret fails too —
one of them would silently win.

## What it renders

- **Deployment** — labels carry the classification (`<prefix>/exposure`,
  `/scaling`, `/wake`, `/gpu`, `/node-pinned`); the selector is name-only,
  because a selector is immutable and folding a mutable class into it would make
  a reclassification a delete-and-recreate. `Recreate` strategy when the app has
  state (a single-writer volume plus a rolling update is a deadlock). **No
  replica count at all** for a scale-to-zero app.
- **Service** — `ClusterIP`, one port per declared port, `targetPort` by name.
  Omitted entirely for an app with no ports.
- **Namespace** — only when `createNamespace`, always with `Prune=false`.
- **Application** — in the app's project, plus `ignoreDifferences` on
  `/spec/replicas` for a scale-to-zero app so Argo CD and the wake front stop
  fighting over the field, plus server-side apply/diff when `adopt`.

Probes are never synthesized — not even readiness. A guessed liveness probe is
the classic way to put a slow-starting app into a restart loop that looks like
the app's fault, so all three probes are exactly what you write and nothing
more.

The wake front's own object (an HTTP scaled object, a middleware) is **not**
rendered here: it needs the hostname requests arrive on, which is a fleet fact.
This grammar records the class; the layer that owns hostnames renders the front.

## Migrating a live app onto the grammar

The rollout hazard is the most likely way this hurts someone, so it is worth
stating plainly:

> A rendered spec is never byte-identical to the YAML it replaces. Labels
> differ, fields this grammar sets appear, fields it does not set disappear.
> Argo CD sees a diff and acts on it.

For a stateless app that is a rollout nobody notices. For a **stateful** one it
is downtime, because `state` forces `Recreate`: the old pod stops before the new
one starts. And the selector cannot be edited in place at all — a Deployment
whose `matchLabels` change must be deleted and recreated.

So, in order:

1. Set `adopt = true`. Server-side apply and diff shrink the diff to what
   genuinely changed rather than a client-side reconstruction of it. That is
   what makes an in-place adoption possible; it does not make the diff zero.
2. Render, and diff the output against what is live *before* syncing.
3. Decide knowingly for each app whether the remaining diff is a rollout you can
   take. For a stateful app on a single-writer volume, that is a maintenance
   window, not a deploy.

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
Twenty declarations, each with exactly one thing wrong, must all be refused,
against a control declaration that must render:

```
control renders, and every guard fires:
  refused: address-literal-in-env               refused: secret-mount-that-is-not-absolute
  refused: address-literal-in-image-registry    refused: secret-referenced-but-never-consumed
  refused: claim-that-is-really-a-path          refused: secret-that-is-really-a-path
  refused: env-and-secret-collide-on-one-variable  refused: state-with-both-backings
  refused: exposed-with-nothing-to-expose       refused: state-with-no-backing
  refused: gpu-scale-to-zero-fronted-by-the-wrong-thing
  refused: hostpath-that-is-not-absolute        refused: stranded-outside-project-destinations
  refused: ipv6-literal-in-env                  refused: targets-a-project-tenancy-never-defines
  refused: liveness-probe-on-an-undeclared-port refused: wake-front-on-an-always-on-app
  refused: namespace-created-by-two-apps        refused: gpu-without-a-named-device-resource
  refused: probe-on-an-undeclared-port
```

And `checks/apps-render.nix` asserts the other direction on the *rendered
manifests*, parsed with a YAML parser rather than trusted: a minimal app renders
both a Deployment and a Service, the selector matches the pod template it
selects, the Service targets a port the container declares, `exposure` and
`scaling` reach the objects, state arrives from either backing, node-path state
says it is pinned, secrets appear only as references, a scale-to-zero app
carries no replica count while its Application ignores that field, a portless
app renders no Service, a created namespace carries `Prune=false`, and a private
overlay's fields land on the grammar's own objects.

## Where domain repositories fit

This module is the vocabulary; it ships no apps. A domain repository (messaging,
media, sharing, ...) exports `nixidyModules` that consume it, so an app recipe
is a declaration rather than a hand-built manifest:

```nix
# nixdomain/apps/example/default.nix — a whole recipe
{ lib, config, ... }:
let cfg = config.nixdomain.example; in
{
  options.nixdomain.example = {
    enable = lib.mkEnableOption "Example, the thing this domain repo ships";
    namespace = lib.mkOption { type = lib.types.str; };
    # A fleet fact taken as a parameter — never written down here.
    dataPath = lib.mkOption { type = lib.types.str; };
  };

  config = lib.mkIf cfg.enable {
    nixk3s.apps.example = {
      inherit (cfg) namespace;
      image = "ghcr.io/example/example:3.2.1@sha256:...";
      ports.http.number = 8080;
      exposure = "nb";
      state.data = { hostPath = cfg.dataPath; mountPath = "/data"; };
      secrets.credentials.envFrom = true;
    };
  };
}
```

The consumer's nixidy env imports both this grammar and the domain module; the
domain module knows the app, this module knows Kubernetes, and neither knows
anyone's addresses.

## Status

New. The vocabulary is not invented: it is what a survey of real self-hosted app
manifests actually declares — which is why `state` has two backings (most apps
sit on a directory somebody curates, not a claim) and why `secrets` is a
first-class term rather than an afterthought. Rendering is proven by
`nix flake check`; unlike its sibling modules, this one has not yet replaced a
live app layer.
