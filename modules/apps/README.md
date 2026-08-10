# `nixk3s.apps`

The **app grammar**: a shared vocabulary for declaring what an app *needs*,
from which this module renders the Argo CD Application, an optional Namespace,
a Deployment whose pod may hold several containers, and a Service.

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
declaration. Four kinds are structurally impossible to write at all:

| Private fact | Why it cannot be written here |
|---|---|
| An address | `exposure` is a *class* (`internal`/`nb`/`public`). Services always render `ClusterIP`; no option reaches `loadBalancerIP`, `externalIPs` or `nodePort`. |
| A path in a name field | `state.<n>.claim`, `state.<n>.configMap`, `state.<n>.secret` and `secrets.<n>.secret` are **names** of existing objects. A value containing `/` fails eval — that is what a path looks like when someone smuggles one through a name field. |
| A uid, gid or fsGroup | `identity` is a **role** ("this app runs as an unprivileged user"). Which user that is on this fleet lives in `appPlatform.identities`, and no app option carries a number. |
| An address in free text | `image`, `env`, `command` and `args` — on the app's own container **and on every companion and init container** — are scanned for IPv4/IPv6 literals and rejected. Container-local addresses (`0.0.0.0`, loopback) are allowed, because those are facts about a container, not about a network. |

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
| `ports` | attrs of `{ number; protocol; servicePort; publish; }` | `{ }` | Named ports on the app's **own** container. `servicePort` is what the Service publishes when it differs; `publish = false` keeps a real port off the Service entirely. Nothing published ⇒ no Service. |
| `companions` | attrs of container | `{ }` | Other containers in **this app's pod** — see below. Not workloads: no second Deployment, no second Service, no selector. |
| `init` | **list** of container | `[ ]` | Containers that run to completion, **in list order**, before the app's. A list because init order is semantics, not style. |
| `exposure` | `internal` \| `nb` \| `public` | `internal` | Who can reach it, as a class — never an address. |
| `scaling` | `always` \| `scale-to-zero` | `always` | Whether it idles at zero. |
| `wake` | `keda` \| `sablier` \| null | `null` | Which wake front. `null` resolves: `sablier` for GPU apps, `keda` otherwise. |
| `gpu` | bool | `false` | Claims the shared GPU: requests one device, forces the `sablier` front when scaling to zero. |
| `replicas` | positive int | `1` | Replica count while running (`always` only). |
| `singleWriter` | bool | `false` | Two live copies are a hazard ⇒ `Recreate`, even with no durable state. Durable state was only ever a proxy for this. |
| `identity` | str or null | `null` | The **role** this pod runs as; resolved through `appPlatform.identities`. `"root"` is reserved and renders a countable `<prefix>/runs-as-root` label. |
| `identityEnv.user` / `.group` | str or null | `null` | Variable NAMES an image reads its ids from. Setting either delivers the identity as environment instead of a `runAsUser`. |
| `security` | five tri-state classes | `null` / `[ ]` | `runAsNonRoot`, `seccomp` (pod); `allowPrivilegeEscalation`, `readOnlyRootFilesystem`, `capabilitiesDrop` (container). Every one of them **restricts** — there is no `privileged`, no `capabilities.add`. |
| `resources.requests` / `.limits` | attrs of str | `{ }` | Compute, **per container**. A GPU device request is added to the app's own container when `gpu` is set. |
| `state` | attrs of volume | `{ }` | Volumes — **one concept, five backings**. Only the two durable ones ⇒ `Recreate`. |
| `secrets` | attrs of `{ secret; envFrom; env; mountPath; containers; optional; }` | `{ }` | Secrets by name, how they are consumed, and which containers consume them. Never the content. |
| `probes.readiness` / `.liveness` / `.startup` | probe or null | `null` | `path = null` probes the TCP socket; otherwise HTTP GET. A probe may only name a port **its own container** declares. |
| `rendersService` | bool | *(read-only)* | Whether this app has an in-cluster address. The **one** authority — a sibling module must read this, never re-derive it from `ports`. |
| `adopt` | bool | `false` | Server-side apply + diff, for taking over objects that already exist. |
| `raw` | list of str | `[ ]` | The escape hatch (above). |

Cluster-wide facts the grammar needs, supplied once:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `nixk3s.appPlatform.defaultProject` | str | `"apps"` | Project an app lands in when it does not say. |
| `nixk3s.appPlatform.labelPrefix` | str | `"nixk3s.dev"` | Prefix for this grammar's own labels. |
| `nixk3s.appPlatform.gpuResourceName` | str or null | `null` | What your device plugin calls a GPU. Unset on purpose: a wrong guess schedules a GPU app with no device and no error, so `gpu = true` fails eval until it is named. |
| `nixk3s.appPlatform.hostPathNodeSelector` | attrs of str | `{ }` | Node selector for apps with node-path state. Which node that is, is a fleet fact — set once, privately. |
| `nixk3s.appPlatform.identities` | attrs of `{ uid; gid; fsGroup; }` | `{ }` | **The identity registry**: role name → numbers. Empty here forever, and holding nothing but numbers. `root` may not be defined. |
| `nixk3s.appPlatform.rawEscapeHatchApps` | list of str | *(read-only)* | Apps still carrying verbatim manifests. |
| `nixk3s.appPlatform.multiContainerApps` | list of str | *(read-only)* | Apps whose pod holds more than one container — the number this vocabulary is judged on. |

### State: one concept, five backings

An app declares "I need this volume"; the consumer decides how it is backed.
Exactly one backing per entry, and none of them is created here — the object
outlives the app, so its existence is not the app's to declare.

```nix
state.config = { claim = "example-config"; mountPath = "/config"; };     # a PVC, by name
state.data   = { hostPath = cfg.dataPath;  mountPath = "/data"; };       # a node path, parameterized
state.conf   = { configMap = "example-conf";                             # a ConfigMap, by name
                 mounts = [ { mountPath = "/etc/app.conf"; subPath = "app.conf"; } ]; };
state.creds  = { secret = "example-creds";                               # a Secret, by name
                 items."tls.crt" = "cert.pem"; mountPath = "/run/certs"; };
state.cache  = { emptyDir = true; mountPath = "/var/cache/app"; };       # scratch, dies with the pod
```

Two of the five are **durable** — the claim and the node path — and only those
switch the Deployment to `Recreate`. A ConfigMap, a Secret or a scratch
directory is not state, and used to force a rolling update off for no reason.

**A volume is declared once and mounted wherever it is needed.** `mountPath` is
the single-mount shorthand; `mounts` is a list of views out of one volume
(`subPath`, per-view `readOnly`); and `companions.<n>.mounts` / `init[].mounts`
give the *other* containers their own views of the same volume. A volume no
container in the pod reads fails eval — it is a typo, not a declaration.

**hostPath pins the pod to a node.** The path only exists on the node that has
it, so the app can only ever run there. On a single-node cluster that is
invisible; the day a second node joins, the app either becomes unschedulable
elsewhere or — worse — starts there against an empty directory. So the grammar
says it out loud: every rendered object gets a `<prefix>/node-pinned` label, an
explicit `nodeSelector` appears when `appPlatform.hostPathNodeSelector` is set,
and an app that is pinned with nothing saying so warns until it is.

**`ownership` decides whether anything chowns the files**, and its default is
the load-bearing half. `fsGroup` makes the kubelet **recursively chown the
volume on every pod start** — merely slow on a claim nothing else touches, and
destructive on a node path somebody curates outside the cluster. So no `fsGroup`
is rendered unless a volume asks for it with `ownership = "kubelet"`.

### One pod, several containers

A pod is the right home for a web front in front of an application, a push
service reading the application's own directory, a metrics exporter — things
that share a network namespace and a set of volumes, and that start, stop and
move as one unit. It is the wrong home for a cache, a database or a queue:
those restart and scale on their own schedule, and belong on their own objects
as typed resources on the same Application.

```nix
nixk3s.apps.example-portal = {
  image = "ghcr.io/example/portal:3.1.0@sha256:...";
  ports.app = { number = 9000; publish = false; };   # real, and nothing outside the pod may reach it

  state.html.hostPath = cfg.dataPath;                # no view here: only the front reads it
  state.html.mounts = [ { mountPath = "/var/www/html"; } ];

  companions.web = {
    image = "ghcr.io/example/front:1.27.0@sha256:...";
    ports.http = { number = 8080; servicePort = 80; };
    mounts.html = [ { mountPath = "/var/www/html"; readOnly = true; } ];
    probes.readiness = { port = "http"; path = "/healthz"; };
  };

  init = [
    { name = "prepare-tree";   image = ...; mounts.html = [ { mountPath = "/var/www/html"; } ]; }
    { name = "assert-secrets"; image = ...; mounts.creds = [ ... ]; }
  ];
};
```

Three things about that are deliberate and worth stating:

- **A companion is not a workload, and cannot become one.** Nothing here renders
  a second Deployment, a second Service, or any object carrying a
  `spec.selector`. That is what keeps the immutable-selector hazard out
  *structurally*: a grammar-generated selector applied to a live object is a
  rejected apply and a permanently `SyncFailed` Application, while a pod
  template is mutable and changing it is a rollout.
- **The Service reaches a companion with no new term for it.** `targetPort`
  renders the port NAME, and Kubernetes requires container port names to be
  unique across the whole pod — so `targetPort: http` finds the companion's
  8080 with no cross-reference and no selector change. The grammar *checks* that
  uniqueness rather than assuming it.
- **`init` is a list and `companions` is an attrset**, and the asymmetry is not
  stylistic. Position carries no meaning to Kubernetes for a container that runs
  for the pod's life, so companions are keyed and sort alphabetically. Init
  order **is** the semantics — the kubelet runs them one after another — and an
  attrset-keyed list renders in attribute-name order, which would silently
  reverse any sequence that is not alphabetical.

A companion may not declare `gpu` (the device is claimed once, by the process
that uses it), `identity` (it is a pod property; a container uid the pod does
not have is a *grant*), `state` (a volume is a pod fact — a companion mounts, it
does not create), or `exposure` / `scaling` / `replicas` / `adopt` (properties
of a workload, which it is not). An init container additionally declares no
ports and no probes: the API server rejects a readiness probe on a
non-restartable init container, and a port on a process that has exited is a
fact about nothing.

There is deliberately no `dependsOn`. It would have to *synthesize* a container,
which means this module choosing an image; the wait semantics genuinely differ
per app; and a term that only knows how to wait on a TCP port is one people
route around at the first awkward case. **A bare wait-for-a-port init container
is still a typed-merge line and should stay one** — this term exists for the
other kind, the one that mounts the app's own volumes or runs the app's own
image.

### Identity: a role here, numbers at the site

```nix
# public: the app names a role and says which shape it wants it in
nixk3s.apps.example.identity = "unprivileged-app";
nixk3s.apps.example.security = { runAsNonRoot = true; seccomp = "RuntimeDefault"; };

# private: what that role IS on this fleet
nixk3s.appPlatform.identities.unprivileged-app = { uid = 4242; gid = 4242; };
```

Naming a role the site has not defined **fails eval**, for the same reason
`gpuResourceName` does: an identity silently dropped is a pod running as root
with nothing in the tree saying so. `identity = "root"` is the reserved way to
say an image must start as uid 0 out loud, and stamps a countable label.

The classes live on the app and the numbers live in the registry on purpose.
Live pod securityContexts are heterogeneous *subsets* — one app carries three
fields, the next two different ones — so a registry that also owned the booleans
would hand every app sharing a role the same bundle, and each would then force
half of it back off.

For the very common image family that starts as root, chowns its own config and
drops privileges itself, `identityEnv = { user = "PUID"; group = "PGID"; }`
delivers the same registry numbers as *environment* and renders no `runAsUser`
— because an image that must start as root cannot also be told not to.

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
  `/scaling`, `/wake`, `/gpu`, `/node-pinned`, `/runs-as-root`); the selector is
  name-only, because a selector is immutable and folding a mutable class into it
  would make a reclassification a delete-and-recreate. The app's own container
  is always keyed `${app.name}` — that key is what every private overlay writes
  against, and no number of companions changes it. `Recreate` strategy when the
  app has durable state or declares `singleWriter` (a single-writer volume plus
  a rolling update is a deadlock). **No replica count at all** for a
  scale-to-zero app.
- **Service** — `ClusterIP`, one port per **published** port on any container of
  the pod, `targetPort` by name. Omitted entirely for an app that publishes
  none.
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

### The ordering seam

Everything this grammar emits from an attrset — containers, `env`, `volumes`,
`volumeMounts` — is rendered in **attribute-name order**, and a hand-written
live object rarely sorts that way. That is an *adoption* artifact with a known
end date, not vocabulary, so it is not a term: it is pinned in the private
overlay with nixidy's `_priority`, on the very keys this module mints.

```nix
# a module the consumer keeps private — reproduce the live order until first rollout
applications.example.resources.deployments.example.spec.template.spec.containers = {
  example = { _priority = 0; };
  sidecar = { _priority = 1; };
};
```

The grammar itself writes no `_priority` and depends on none. Mount keys are
stable and documented for exactly this reason: the first mount of a volume takes
the volume's own name, and the second and later take `<volume>-01`, `<volume>-02`.

Two adoption rules follow, and both cost real downtime when missed:

1. **Diff the rendered container LIST, not just the fields.** Declaring a
   companion on a live app reorders its container list unless the live order
   happens to be alphabetical — and on a `Recreate` app that is a stop-then-start
   for no behaviour change. Render it, diff it, and pin the order *before* the
   first sync.
2. **Adopting `init` means moving ALL of the app's init containers into it, in
   the same commit.** This module cannot see a private `initContainers` overlay,
   and one left behind does not append — it lands at its own alphabetical
   position among the grammar's ordered ones and interleaves.

### Two house-style notes

- **A wake front goes on `applications.<app>.yamls`, not on the app's `raw`.**
  `raw` is part of the app's *public* declaration surface, and a wake front needs
  the hostname requests arrive on. Putting it on the private Application's
  passthrough keeps the fleet fact private, and keeps `rawEscapeHatchApps`
  counting apps that carry untyped manifests **of their own**.
- **`enableServiceLinks` is a real footgun and has no term here.** Kubernetes
  injects `<SERVICE>_PORT=tcp://…` for every Service in the namespace, which
  overwrites an identically named variable the app defines itself. When that
  bites, it is one typed-merge line on the pod spec — per-app knowledge nobody
  should generalize.

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
**65 declarations**, each with exactly one thing wrong, must all be refused,
against **9 control declarations** that must render. The check prints both
lists, so this README does not carry a copy that can rot.

Two things make it more than a smoke test:

- **Every refusal must come with a message of its own.** `tryEval` can only say
  *that* a declaration was refused, so a case stopped by a typo, or by a
  neighbouring guard firing first, would pass silently. The assertion-shaped
  cases are read back through `applications.<app>.assertions`, and one that
  produces no failing assertion fails the check.
- **The ill-typed cases are held separately, and they are the point.** Four
  options are read by some render site on only *one* side of a branch —
  `hostPathType` (only beside a hostPath), `replicas` (only when `scaling =
  "always"`), `items` (only on a keyed backing), `servicePort` (only when the
  app renders a Service at all) — so before a guard read them unconditionally,
  their values were accepted, discarded, and **never type-checked**. Only the
  ill-typed half proves a value is *forced* rather than merely compared. See
  [`../../studies/what-forces-this-option.md`](../../studies/what-forces-this-option.md).

The nine controls exist for the same reason: without a `sleeping-control`,
"scale-to-zero was refused at all" would read as proof that the replica count
had been checked; without `multi-container-control`, "a companion was refused at
all" would be what makes twenty companion cases look green; and
`unpublished-control` / `companion-only-port-control` are the two directions of
"does this app have an address" — one declares a port and publishes none, the
other declares none and publishes its companion's.

And `checks/apps-render.nix` asserts the other direction on the *rendered
manifests*, parsed with a YAML parser rather than trusted: a minimal app renders
both a Deployment and a Service, the selector matches the pod template it
selects, the Service targets a port the container declares, `exposure` and
`scaling` reach the objects, state arrives from every backing, node-path state
says it is pinned, secrets appear only as references and only on the containers
named, a companion renders beside the app's own container while that container
keeps its name, **init containers render in written and deliberately
non-alphabetical order**, an unpublished port stays on the container and off the
Service, an identity resolves to numbers in both spellings, a scale-to-zero app
carries no replica count while its Application ignores that field, a portless
app renders no Service, a created namespace carries `Prune=false`, and a private
overlay's fields land on the grammar's own objects.

The init-order assertion carries its own vacuity guard: if the two container
names ever stop being in *reverse* alphabetical order, the check fails and says
so, because an attribute-keyed render would have passed it too.

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
manifests actually declares — which is why `state` has a node-path backing at
all (most apps sit on a directory somebody curates, not a claim), why `secrets`
is a first-class term rather than an afterthought, and why `identity` is a role
rather than a number. Rendering is proven by `nix flake check`; unlike its
sibling modules, this one has not yet replaced a live app layer.

The multi-container half — `companions` and `init` — is the newest and the
largest surface, which is why `appPlatform.multiContainerApps` is read-only and
countable. Whether a pod vocabulary earns that surface is a number, not an
argument: if the list stays at one entry, the honest reading is that the
minimal-surface shape was right and this should come back out before a second
app depends on it.
