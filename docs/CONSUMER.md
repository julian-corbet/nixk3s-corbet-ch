# Consuming the app grammar from a catalogue

`lib.mkConsumerModule` is the catalogue-to-grammar translator. It keeps the software facts in a
public catalogue and the cluster values in a declaration, then renders through `nixk3s.apps`.

## One catalogue

The small form is unchanged:

```nix
nixidyModules.example = nixk3s.lib.mkConsumerModule {
  namespace = "nixexample";
  catalogue = self.lib.applications;
};
```

This declares `nixexample.clusterPlatform` and `nixexample.applications`. Each application selects
an entry with `app`; enabled declarations render through the app grammar. `root`, `selector`,
`platformOption`, `extraOptions`, `extend`, and the assertion/warning hooks remain available for a
single unusual catalogue.

`namespace` is also the stable label used in diagnostics. When an established public schema is
nested, `optionPath` places the factory options there without a mirror module or a new sibling
surface:

```nix
nixk3s.lib.mkConsumerModule {
  namespace = "nixoffice";
  optionPath = [ "nixoffice" "cluster" ];
  catalogue = self.lib.applications;
}
```

This declares `nixoffice.cluster.clusterPlatform` and `nixoffice.cluster.applications`, while
diagnostics still begin with `nixoffice:`. `optionPath` defaults to `[ namespace ]` and must be a
non-empty list of non-empty strings.

An established schema may already keep its platform values flat and have no compatible place for
the factory's nested platform node. In that case the consumer can suppress only that publication
and resolve the same internal record from its typed domain options:

```nix
nixk3s.lib.mkConsumerModule {
  namespace = "nixexample";
  publishPlatformOptions = false;
  platformOf = { consumer, ... }: {
    inherit (consumer) namespace project origin;
  };
  originOptionPath = [ "nixexample" "origin" ];
  extraNamespaceOptions = {
    namespace = lib.mkOption { type = lib.types.str; };
    project = lib.mkOption { type = lib.types.str; };
    origin = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
  };
  catalogue = self.lib.applications;
}
```

`platformOf` is required when `publishPlatformOptions = false`; it receives `consumer` and
`moduleConfig` and must return string `project`, nullable-string `origin`, and string `namespace`
when any root exposes the common namespace term. `extraPlatformOptions` are unavailable in this
mode because there is deliberately no platform subtree to hold them. `originOptionPath` keeps the
shared slot diagnostic pointed at the real option; it otherwise defaults to the published
`${platformOption}.origin` path.

## Several roots and mixed delivery kinds

A database tier or CI platform is not one homogeneous table. An instance can be a typed workload
or an operator-owned custom resource; a forge can be a workload or a reference to somebody else's
service. The rendering kind therefore comes from the selected catalogue entry:

```nix
nixk3s.lib.mkConsumerModule {
  namespace = "nixexample";

  extraPlatformOptions = {
    controlNamespace = lib.mkOption { type = lib.types.str; };
    executionNamespace = lib.mkOption { type = lib.types.str; };
  };

  roots = {
    services = {
      catalogue = catalogue.services;
      selector = "service";
      kind = { entry, ... }: entry.delivery; # app | manifest | reference

      # The catalogue decides the plane; the cluster supplies what each plane is called.
      disabledOptions = [ "namespace" ];
      namespaceOf = { entry, platform, ... }:
        if entry.plane == "execution"
        then platform.executionNamespace
        else platform.controlNamespace;

      # Entry knowledge may choose a default or park an entry. Either remains overridable by the
      # declaration because the factory applies it with mkDefault.
      enableByDefault = { entry, ... }: entry.enabledByDefault or true;
      defaults = { entry, ... }: {
        exposure = entry.defaultExposure or "internal";
      };
    };

    jobs = {
      # A schedule has no catalogue key. A fixed synthetic entry avoids inventing one.
      entry = jobEntry;
      kind = { entry, ... }: entry.delivery;
      disabledOptions = [ "namespace" "exposure" "slot" ];
      namespaceOf = { platform, ... }: platform.controlNamespace;
    };
  };
}
```

The three kinds are intentionally few:

| Kind | Result |
|---|---|
| `app` | A full `nixk3s.apps.<name>` declaration. Whole `manifests` are refused. |
| `manifest` | One Argo CD Application carrying opaque YAML, with server-side apply and diff. An empty list renders nothing and warns. |
| `reference` | No object. The declaration remains visible to domain interlocks and in `notRendered`. |

Rendered charts and custom resources share `manifest` because the factory interprets neither
schema. The schema belongs to the chart or operator API version; the value supplied here is only
the resulting YAML.

## Root fields

| Field | Meaning |
|---|---|
| `catalogue` + `selector` | Select an entry from an attrset. `selectorDefault` and `selectorDescription` are optional. Mutually exclusive with `entry`; the selector name must not collide with a common or extra option. |
| `entry` | One fixed synthetic entry; no selector option is declared. |
| `kind context` | Returns `app`, `manifest`, or `reference`. |
| `enableByDefault context` | Entry-derived default for `enable`; the declaration can override it. |
| `defaults context` | Entry-derived declaration defaults, applied with `mkDefault`. |
| `disabledOptions` / `enabledOptions` | Remove cluster terms structurally per root. Setting a removed term is an unknown-option error. |
| `namespaceOf`, `projectOf`, `createNamespaceOf`, `nameOf` | Resolve fields that may be derived rather than writable. `nameOf` is the rendered object identity for both grammar apps and direct Applications. |
| `manifestsOf` | Supplies opaque YAML for a `manifest` entry; defaults to `w.manifests`. |
| `volumeNameOf context key` | Resolves a public state key to its rendered Kubernetes volume identity. It defaults to the declaration's `volumeName`, then the key. The resolved name is used for app state, companion/init mounts, ordering and collision guards, and DNS-label validation. |
| `requiredStateKeys`, `allowedStateKeys` | Refine catalogue state per entry/declaration. Both default to every catalogue state key. The factory enforces required ⊆ allowed ⊆ catalogued and required ⊆ declared ⊆ allowed. |
| `extend`, `extendManifest` | Add the genuinely domain-specific tail to the typed or manifest result. |
| `extraOptions` | Extra declaration options for this root. |
| `assertions`, `warnings` | Root-local guards over the root's enabled workload contexts. |
| `description`, `example` | Documentation carried by the root option without changing its renderer. |

`extraOptions` overlays the common option surface for two deliberate, distinct cases. Overlaying an
ENABLED common name refines its module contract while keeping the shared renderer and guards; for
example, a root may narrow nullable `version` to a required string, or replace `state` with an
existing claim/hostPath-only public subtype. The renderer treats omitted optional backing fields as
their common defaults, so narrowing the writable state schema does not surrender the central state
guards. Overlaying a STRUCTURALLY
DISABLED common name replaces its shape and transfers responsibility to that root. The factory
uses the original enabled/disabled marker—not the final overlaid option set—to distinguish them.

That responsibility transfer is concrete for the incompatible shapes found in existing consumers:

- Replacing `credentials` makes the factory emit no generic secrets and skip its variable-shaped
  credential assertions. The root supplies `app.secrets` through `extend` and carries its
  known/required-role and isolation guards in `assertions`.
- Replacing `state` makes the factory emit no generic state, skip its state/volume/nesting guards,
  and leave catalogue companion/init mount keys untouched. The root's `extend` must translate its
  state, remap every container mount, and supply equivalent domain guards.
- Replacing `resources` or `companionResources` makes the corresponding base sizing empty and
  skips inspection of the replacement record. The root's `extend` renders that sizing and owns any
  shape-specific validation.

This is an explicit transfer of the renderer and safety boundary, not an untyped fallback.

Extensions own domain payload, not identity or tenancy. After `extend`, the factory reapplies the
resolved app `name`, `namespace`, `project`, and `createNamespace`, because its collision and
namespace-anchor guards reason about those callback results. After `extendManifest`, it likewise
reapplies `namespace`, `project`, `createNamespace = false`, exact `yamls`, server-side apply, and
server-side diff. A direct Application has no second name field: its module key is already the
identity returned by `nameOf`.

For an `app` delivery, the `nixk3s.apps` module key remains the declaration name while `nameOf`
sets the rendered app and object name. That preserves the consumer's stable option path during an
adoption. A direct Application has no grammar declaration beneath it, so its module key is the
resolved name instead. The factory checks both rendered-name collisions and module-key collisions;
neither naming space is allowed to merge two deliveries accidentally.

Every callback receives a context containing `root`, `name`, `selected`, `entry`, `declaration`,
`w`, `platform`, `consumer` (the namespace's complete configuration), `moduleConfig` (the complete
nixidy configuration), `spec`, and `kind` (except while `kind` itself is being computed).
`declaration` is the resolved record shaped by that root's actual options; `w` totalizes removed
common options with closed/null internal values so shared rendering and guards remain safe. A
callback that needs to distinguish a structurally absent option must therefore inspect
`declaration`, not `w`.

`consumer` is how a root derives wiring from a declared peer without copying its namespace or
service name into a second declaration.

The shared `${platformOption}.namespace` option exists only when at least one root exposes the
common per-workload `namespace` term. If every root removes that term and derives its namespace
from category/side/plane fields, the factory does not invent a singular required platform
namespace; declare those domain fields in `extraPlatformOptions` and resolve them in `namespaceOf`.
The one-catalogue form still exposes the common term by default and therefore retains its required
platform namespace.

### Callback phases

`kind`, `enableByDefault`, and `defaults` participate in resolving the declaration; the field
resolvers (`namespaceOf`, `projectOf`, `createNamespaceOf`, `nameOf`, `manifestsOf`, `volumeNameOf`,
`requiredStateKeys`, and `allowedStateKeys`) participate in constructing or classifying its output.
These callbacks may read catalogue knowledge, platform values, and already-declared peers through
`consumer`. They must not read the rendered reports or the `moduleConfig.applications` output they
are helping construct: doing so closes the module fixed point through its own result and can
recurse.

Root `assertions` and `warnings` run over the enabled, classified contexts and are the place for
post-construction interlocks. For example, an empty manifest declaration can use a root assertion
over `moduleConfig.applications` to prove that another module in the same environment really
delivers its object. `extraConfig` then publishes domain reports or sibling module definitions from
the same context list.

The namespace also reports `clusterSlots`, `renderedByGrammar`, `renderedDirectly`, and
`notRendered`. Cross-root duplicate names, duplicate slots, duplicate rendered names, and multiple
namespace anchors are refused centrally. `extraPlatformOptions`, `extraNamespaceOptions`, and
`extraConfig` let a domain publish its own computed reports without forking the translator; its
result is deep-merged as a module definition, so a sibling `nixk3s.*` subtree cannot replace
`nixk3s.apps`.

When the `${platformOption}.origin` field at `optionPath` is set, every slot held by a `manifest`
or `reference` entry is also emitted as `nixk3s.addressing.reservations.<name>`. Addressing already counts slots on
grammar apps; the reservation keeps a below-grammar holder from making a live number appear free.
Compose the addressing module whenever an origin is set, just as the single-catalogue form already
requires for grammar-app slots.

The complete executable example is in [`examples/consumer/multi-root-module.nix`](../examples/consumer/multi-root-module.nix), with fail-closed checks in [`checks/consumer-multi-root.nix`](../checks/consumer-multi-root.nix).
