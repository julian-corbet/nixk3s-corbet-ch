# nixk3s.apps — the app grammar: a shared vocabulary for declaring WHAT AN APP
# NEEDS, from which this module renders the Kubernetes objects.
#
# WHY A GRAMMAR AT ALL. Every hand-written workload module re-implements the
# same scaffolding: an `image`, a `port`, a namespace, then a couple of hundred
# lines hand-building a Deployment and a Service that differ from the next
# app's in about six places. That repetition IS the missing abstraction. Here
# an app declares its needs in a dozen lines and this module renders the rest,
# so the six places that actually differ are the only six things anyone writes.
#
# AN APP IS NOT A PLANE. The sibling deployment project states the principle
# this module obeys: keeping the boot object BELOW the configuration plane
# preserves two independent axes without pretending either role is a plane. An
# app sits below the cluster plane in exactly that way. So there is no
# `cluster`, no `target`, no `host` option here and there never will be: an app
# does not name where it runs. It declares needs; the cluster it is rendered
# into is a property of the render, not of the app.
#
# THE PUBLIC/PRIVATE BOUNDARY — the reason this vocabulary can live in a public
# repository at all:
#
#   An app declares NEEDS. Someone else supplies the VALUES.
#
# Options are parameters. This repository declares them; a private consumer
# sets them — exactly the way `namespace` already works. What must never happen
# is a fleet fact getting BAKED IN here: no address, no slot, no octet, no UID,
# no storage path appears in this file or in any public declaration written
# against it. Three of those are structurally impossible to write at all:
#
#   - `exposure` is a CLASS (`internal` / `nb` / `public`), never an address.
#     Services render `ClusterIP`, always; nothing here reaches
#     `loadBalancerIP`, `externalIPs` or `nodePort`.
#   - `state.<name>.claim` and `secrets.<name>.secret` are NAMES of objects that
#     already exist. A value containing `/` fails eval — that is what a storage
#     path looks like when someone tries to smuggle one through a name field.
#   - Free-text values (`image`, `env`, `command`, `args`) are scanned for IP
#     literals and rejected. Container-local addresses (`0.0.0.0`, loopback)
#     are allowed, because those are facts about a container, not a network.
#
# `state.<name>.hostPath` is the one term whose VALUE is unavoidably a path —
# because two thirds of real apps are backed that way, and a grammar that
# cannot say so is a grammar people bypass. It is a parameter like any other:
# the app declares it needs a path, the private consumer passes one in.
#
# TWO WAYS OUT, both deliberate and both visible:
#
#   1. TYPED MERGE (preferred). A consumer's private module defines more fields
#      on the very objects rendered here — `applications.<app>.resources...` —
#      and the module system merges them. That is how a pinned ClusterIP, an
#      init container, a UID, or a pod-spec knob this vocabulary has no term
#      for gets set, without any of it entering the public declaration.
#   2. `raw` — YAML documents passed through with no typing and no schema
#      defaults injected, for whole objects the grammar has no term for at all
#      (a wake-front CR, a ConfigMap). It is deliberately NOT scanned, so it is
#      the one place the boundary stops being enforced: hence every app that
#      uses it warns at render, and `appPlatform.rawEscapeHatchApps` lists them
#      so the number is countable rather than a vague worry. An abstraction
#      people route around is worse than one visible hatch.
#
# THE TWO TENANCY LESSONS, paid for in production and encoded here so they
# cannot be rediscovered (see modules/tenancy for the long form):
#
#   1. An Argo CD Application whose target namespace is missing from its
#      AppProject's `destinations` does not degrade gracefully — it goes to
#      `InvalidSpecError` and refuses to sync AT ALL, including for healthy
#      resources already in that namespace. Whenever the tenancy module is in
#      the same render, every app here is CHECKED against its project's
#      destination list and fails eval if it would be stranded. Rendering an
#      app that cannot sync is worse than not rendering it.
#   2. A namespace holding live/stateful contents MUST carry `Prune=false`, or
#      a manifest slip elsewhere in the tree makes Argo CD read the Namespace
#      itself as no-longer-desired and cascade-delete everything inside it.
#      Every namespace this grammar creates is stamped `Prune=false`
#      explicitly, and no option can turn that off.
{ lib, config, ... }:
let
  cfg = config.nixk3s.apps;
  platform = config.nixk3s.appPlatform;

  # The tenancy module is a SIBLING, not a dependency: this grammar renders
  # perfectly well without it (a consumer may govern projects some other way).
  # When it IS present in the same render, lesson 1 above becomes checkable, so
  # we check it. `or null` keeps the reference legal when the option does not
  # exist at all.
  tenancy = config.nixk3s.tenancy or null;
  tenancyActive = tenancy != null && tenancy.enable;

  # Argo CD's built-in project allows every destination, so it is the one
  # project the interlock cannot (and need not) check against.
  builtinProject = "default";

  ## ---------------------------------------------------------------------
  ## Address-literal guard (the public boundary, enforced rather than asked
  ## for). Nix has no substring regex search, so `builtins.split` does the
  ## work: it returns the capture lists of every match interleaved with the
  ## unmatched text, and capture 1 of each match is the literal we care about.
  ## ---------------------------------------------------------------------

  # Addresses that are facts about a container, not about a network: bind-any,
  # loopback, and the unspecified address. Rejecting these would break ordinary
  # `HOST=0.0.0.0` configuration for no privacy gain.
  localAddresses = [ "0.0.0.0" "127.0.0.1" "::1" "::" ];

  ipv4Literals = s:
    lib.filter (m: !(lib.elem m localAddresses))
      (map builtins.head
        (lib.filter builtins.isList
          (builtins.split "(([0-9]{1,3}[.]){3}[0-9]{1,3})" s)));

  # Tokens that could be an IPv6 literal are the maximal runs of hex digits and
  # colons; a token counts as an address if it is either compressed (contains
  # `::` and at least one hex digit) or a full eight-group form. Anything else
  # — a digest, a timestamp, a version — is left alone.
  ipv6Literals = s:
    let
      tokens = lib.filter lib.isString (builtins.split "[^0-9a-fA-F:]+" s);
      looksIpv6 = t:
        (builtins.match "[0-9a-fA-F:]*::[0-9a-fA-F:]*" t != null
        && builtins.match ".*[0-9a-fA-F].*" t != null)
        || builtins.match "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}" t != null;
    in
    lib.filter (t: looksIpv6 t && !(lib.elem t localAddresses)) tokens;

  addressLiterals = s: ipv4Literals s ++ ipv6Literals s;

  # An image reference is scanned only across its REGISTRY component — the part
  # before the first `/`. That is the only place an address can appear in an
  # image reference, and scanning the whole string would reject a legitimate
  # four-component version tag as if it were a dotted quad.
  imageRegistry = image: lib.head (lib.splitString "/" image);

  # Every free-text value on one app, paired with where it came from, so a
  # rejection can name the exact field instead of just the app. `raw` is
  # deliberately absent: see the escape-hatch note in the header.
  scannedStrings = app:
    [{ where = "image"; value = imageRegistry app.image; }]
    ++ lib.mapAttrsToList (k: v: { where = "env.${k}"; value = v; }) app.env
    ++ lib.imap0 (i: v: { where = "command[${toString i}]"; value = v; }) app.command
    ++ lib.imap0 (i: v: { where = "args[${toString i}]"; value = v; }) app.args;

  offendingStrings = app:
    lib.filter (s: addressLiterals s.value != [ ]) (scannedStrings app);

  ## ---------------------------------------------------------------------
  ## Derived facts
  ## ---------------------------------------------------------------------

  enabledApps = lib.filterAttrs (_: app: app.enable) cfg;

  # Which wake front fronts a scaled-to-zero app. `null` for an always-on app:
  # there is nothing to wake, and the label is then absent rather than lying.
  wakeFrontOf = app:
    if app.scaling != "scale-to-zero" then null
    else if app.wake != null then app.wake
    else if app.gpu then "sablier"
    else "keda";

  stateEntries = app: lib.attrValues app.state;
  secretEntries = app: lib.attrValues app.secrets;

  # Volumes carrying a `hostPathType` that no backing of theirs will ever read.
  # `volumesOf` reads the field only on the hostPath side of an `if`, so on a
  # claim-backed volume the value was discarded before anything forced it — and
  # an option nothing forces is an option whose type is never checked. The
  # predicate therefore reads it as its FIRST term, which forces it on both
  # sides of that `if` rather than leaning on the render for one of them.
  strayHostPathTypes = app:
    lib.attrNames
      (lib.filterAttrs (_: st: st.hostPathType != "Directory" && st.hostPath == null) app.state);

  # hostPath-backed state pins the pod to whichever node holds that path. On a
  # one-node cluster that is invisible; the day a second node joins it becomes
  # "the app runs, and silently reads a different (or empty) directory".
  nodePinned = app: lib.any (st: st.hostPath != null) (stateEntries app);

  # The selector is name-only and MUST stay that way: a Deployment's selector
  # is immutable after creation, so folding a mutable classification like
  # `exposure` into it would make changing that class a delete-and-recreate.
  selectorOf = app: { "app.kubernetes.io/name" = app.name; };

  labelsOf = app:
    let front = wakeFrontOf app; in
    selectorOf app
    // {
      "app.kubernetes.io/managed-by" = "nixk3s";
      "${platform.labelPrefix}/exposure" = app.exposure;
      "${platform.labelPrefix}/scaling" = app.scaling;
    }
    // lib.optionalAttrs (front != null) { "${platform.labelPrefix}/wake" = front; }
    // lib.optionalAttrs app.gpu { "${platform.labelPrefix}/gpu" = "true"; }
    // lib.optionalAttrs (nodePinned app) { "${platform.labelPrefix}/node-pinned" = "true"; };

  gpuLimits = app:
    lib.optionalAttrs (app.gpu && platform.gpuResourceName != null) {
      ${platform.gpuResourceName} = 1;
    };

  # Namespaces this render CREATES, and who creates them. Two Applications both
  # creating one Namespace is two Argo owners for one object; caught below.
  creatorsOf = namespace:
    lib.attrNames (lib.filterAttrs
      (_: app: app.createNamespace && app.namespace == namespace)
      enabledApps);

  ## ---------------------------------------------------------------------
  ## Types
  ## ---------------------------------------------------------------------

  portType = lib.types.submodule {
    options = {
      number = lib.mkOption {
        type = lib.types.port;
        description = ''
          Port the container listens on. A container-side number, which is a
          property of the software, not of any network — the one kind of number
          this grammar does accept.
        '';
      };

      protocol = lib.mkOption {
        type = lib.types.enum [ "TCP" "UDP" "SCTP" ];
        default = "TCP";
        description = "IP protocol for this port.";
      };
    };
  };

  stateType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          NAME of an existing PersistentVolumeClaim to mount. A name, never a
          path: which storage backs the claim is decided outside the app, and a
          value containing `/` fails eval.

          This grammar never CREATES the claim, and that is the point: the claim
          outlives the app, so its existence is not the app's to declare.
        '';
      };

      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path on the NODE to mount instead of a claim. The other backing, and
          in practice the more common one — most self-hosted apps sit on a
          directory somebody already curates.

          IT PINS THE POD TO A NODE. The path only exists on the node that has
          it, so the app can only ever run there. On a single-node cluster that
          is invisible; the day a second node joins, this app either becomes
          unschedulable elsewhere or — worse — runs there against a different
          or empty directory. Set `nixk3s.appPlatform.hostPathNodeSelector` and
          the pin becomes an explicit `nodeSelector` instead of a surprise; the
          rendered objects also carry a `<prefix>/node-pinned` label either way.

          The VALUE is a fleet fact and belongs to the private consumer that
          passes it in. A public declaration takes it as a parameter (exactly
          like `namespace`) and never writes one down.
        '';
      };

      hostPathType = lib.mkOption {
        type = lib.types.enum [
          "Directory"
          "DirectoryOrCreate"
          "File"
          "FileOrCreate"
          "Socket"
          "CharDevice"
          "BlockDevice"
        ];
        default = "Directory";
        description = ''
          `hostPath.type` for a hostPath backing. `Directory` (the default)
          refuses to start the pod when the path is missing, which is the safe
          answer for state that must already exist; `DirectoryOrCreate` creates
          an empty one, and is how an app silently comes up with no data.

          FOR A HOSTPATH BACKING ONLY. Which storage backs a claim is decided
          outside the app, so setting this beside a `claim` fails eval instead
          of being dropped on the way to the manifest.
        '';
      };

      mountPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute path INSIDE the container where this volume is mounted — a
          container-internal fact (`/config`, `/data`), not a host path.
        '';
      };

      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount read-only.";
      };
    };
  };

  secretType = lib.types.submodule ({ name, ... }: {
    options = {
      secret = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = ''
          NAME of an existing Secret. Naming a secret is a need; supplying it is
          the consumer's job — this grammar has no option that carries a
          secret's CONTENT, and never will, because everything it renders is
          committed to git. Where the Secret comes from (a sealed secret, an
          operator, kubectl) is outside the app's business.
        '';
      };

      envFrom = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Inject every key in the Secret as an environment variable. Convenient,
          and blunt: the app gets whatever the Secret happens to contain, so a
          key added later lands in the process environment unannounced. Prefer
          `env` when you know the keys.
        '';
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { DATABASE_PASSWORD = "password"; };
        description = ''
          Environment variables sourced from individual keys, as
          `<VARIABLE> = "<key in the Secret>"`. Renders `secretKeyRef`, so the
          value never passes through Nix or the rendered tree.
        '';
      };

      mountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute path inside the container to mount the Secret at, one file
          per key. For apps that read credentials from a file rather than the
          environment. Mounted read-only.
        '';
      };

      optional = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let the pod start when the Secret does not exist. Off by default: an
          app that silently starts without its credentials fails later, further
          from the cause.
        '';
      };
    };
  });

  probeType = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.str;
        description = "Name of one of this app's declared `ports` to probe.";
      };

      path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          HTTP path to GET. `null` (the default) probes the TCP socket instead
          — the right answer for anything that is not an HTTP server, and the
          honest one for an HTTP server with no cheap health endpoint.
        '';
      };

      initialDelaySeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = "Delay before the first probe.";
      };

      periodSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Interval between probes.";
      };

      failureThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          Consecutive failures before the probe's verdict is acted on. This is
          the number that decides how long a slow start is tolerated
          (`periodSeconds * failureThreshold`), and the usual cause of a
          restart loop on a big application is leaving it at the default.
        '';
      };

      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "How long one probe may take before it counts as failed.";
      };
    };
  };

  appType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to render this app. Declaring the attribute is declaring the
          app, so this defaults to true; set false to park a declaration
          without rendering it.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Name of the app, its objects, and its Argo CD Application.";
      };

      namespace = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Namespace this app lands in.";
      };

      createNamespace = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this app creates its namespace. Defaults to false: a
          namespace usually outlives any one app in it, and where it does, the
          right owner is the tenancy layer that anchors it (see the tenancy
          module's `namespaces`), not whichever workload arrived first.

          A namespace created here is ALWAYS stamped
          `argocd.argoproj.io/sync-options: Prune=false`, and there is no
          option to turn that off — see the lesson at the top of this file.
        '';
      };

      project = lib.mkOption {
        type = lib.types.str;
        default = platform.defaultProject;
        defaultText = lib.literalExpression "config.nixk3s.appPlatform.defaultProject";
        description = ''
          Argo CD AppProject this app's Application belongs to. When the
          tenancy module is part of the same render, `namespace` must appear in
          this project's `destinationNamespaces` or eval fails — an Application
          outside its project's destinations is refused wholesale by Argo CD.
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        description = ''
          Container image. PIN IT BY DIGEST
          (`registry/name:tag@sha256:<digest>`): a tag is a moving target, and
          a GitOps tree whose rendered manifests are identical across two syncs
          that produce different running code is a tree that cannot be audited.
          A tag-only image renders fine and warns.
        '';
      };

      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Container entrypoint override. Empty means the image's own.";
      };

      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Arguments to the entrypoint.";
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Plain environment variables. PLAIN is the operative word: a secret
          belongs in `secrets` (a rendered manifest is committed to git in this
          spine), and an address belongs to whatever allocates addresses —
          values are scanned for IP literals and rejected, so a fleet fact
          cannot enter through the one free-text field.
        '';
      };

      ports = lib.mkOption {
        type = lib.types.attrsOf portType;
        default = { };
        description = ''
          Named ports the container listens on. The attribute name is the port
          name used by the Service and by the probes. An app with no ports (a
          worker, a cron-shaped process) renders no Service at all.
        '';
      };

      exposure = lib.mkOption {
        type = lib.types.enum [ "internal" "nb" "public" ];
        default = "internal";
        description = ''
          WHO can reach this app, as a class — never an address:

            - `internal` — reachable inside the cluster only.
            - `nb`       — reachable to peers of the private overlay network
                           the cluster is a member of.
            - `public`   — reachable from the internet.

          Today the class is recorded on every rendered object as a label, so
          the front that implements it (an ingress, a tunnel, an overlay route)
          can select on it and be added without reshaping any app declaration.
          What the class NEVER becomes here is a number: no LoadBalancer
          address, no node port, no hostname. Those are fleet facts, allocated
          where fleet facts belong.
        '';
      };

      scaling = lib.mkOption {
        type = lib.types.enum [ "always" "scale-to-zero" ];
        default = "always";
        description = ''
          `always` — a running replica count this app owns.
          `scale-to-zero` — idles at zero replicas; a wake front brings it up on
          demand. The rendered Deployment then carries NO replica count and the
          Argo CD Application ignores `/spec/replicas`, because the wake front
          owns that field: leave it in the manifest and every sync fights the
          autoscaler over it.

          The front's own object (an HTTP scaled object, a middleware) is NOT
          rendered here: it needs the hostname requests arrive on, which is a
          fleet fact. This grammar records the class; the layer that owns
          hostnames renders the front.
        '';
      };

      wake = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
        default = null;
        description = ''
          Which wake front fronts a `scale-to-zero` app. `null` picks one:
          `sablier` when the app needs the GPU, `keda` otherwise. Meaningless
          for an `always` app, and setting it there fails eval rather than
          rendering a label about a front that will never exist.
        '';
      };

      gpu = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          This app claims the shared GPU. Two consequences: the container
          requests one device (`nixk3s.appPlatform.gpuResourceName`, which the
          operator must name — nothing is guessed), and a scale-to-zero GPU app
          is fronted by `sablier`, not `keda`.

          The reason for that second one is the device, not the protocol: a
          request that arrives while the app is down must BLOCK until the pod
          actually holds the card, and be answered by the app itself. A front
          that admits the request earlier turns "the GPU is busy" into a
          five-hundred at the edge.
        '';
      };

      replicas = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = ''
          Replica count while running. Only meaningful with
          `scaling = "always"`; a scale-to-zero app's count belongs to its wake
          front and this value is not rendered — so declaring one there fails
          eval rather than quietly rendering nothing, exactly like naming a
          `wake` front on an always-on app.
        '';
      };

      resources = {
        requests = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = { cpu = "50m"; memory = "64Mi"; };
          description = ''
            Compute the scheduler must find for this app. Requests are what
            scheduling is actually based on; an app with none is placed as if
            it were free.
          '';
        };

        limits = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = { memory = "256Mi"; };
          description = ''
            Ceilings. A memory limit is a kill threshold, which is usually what
            you want for a leaky app; a CPU limit is a throttle, which is
            usually not — it makes a bursty app slow rather than a noisy one
            quiet. A GPU device request, when `gpu` is set, is added here
            automatically.
          '';
        };
      };

      state = lib.mkOption {
        type = lib.types.attrsOf stateType;
        default = { };
        description = ''
          Persistent state this app NEEDS, keyed by volume name. Each entry is
          backed by EITHER an existing claim (`claim`) OR a path on the node
          (`hostPath`) — one concept, two backings, because that is what real
          apps divide into. Exactly one backing per entry; neither is created
          here.

          Declaring any state also switches the Deployment to the `Recreate`
          strategy: a single-writer volume plus a rolling update is a deadlock,
          where the new pod waits for a volume the old pod will not release
          until the new one is ready.
        '';
      };

      secrets = lib.mkOption {
        type = lib.types.attrsOf secretType;
        default = { };
        description = ''
          Secrets this app NEEDS, keyed by a local name (the Secret's own name
          defaults to it). Each entry says how the app consumes it: whole-Secret
          `envFrom`, named keys as `env` variables, a `mountPath`, or several at
          once — but at least one, because a reference nothing consumes is a
          typo, not a declaration.

          The app names a Secret; it never carries the content. Nothing in this
          vocabulary can express a secret's value, so a declaration is safe to
          publish even when the Secret it names is not.
        '';
      };

      probes = {
        readiness = lib.mkOption {
          type = lib.types.nullOr probeType;
          default = null;
          description = ''
            Readiness probe: gates Service endpoints and rollouts. The one probe
            almost every app should have, and the cheapest to get right.
          '';
        };

        liveness = lib.mkOption {
          type = lib.types.nullOr probeType;
          default = null;
          description = ''
            Liveness probe: restarts the container when it fails. NEVER
            synthesized, only ever what you write here — a guessed liveness
            probe is the classic way to put a slow-starting app into a restart
            loop that looks like the app's fault. Give it a real
            `failureThreshold`, or leave it null and let readiness do its job.
          '';
        };

        startup = lib.mkOption {
          type = lib.types.nullOr probeType;
          default = null;
          description = ''
            Startup probe: suspends the liveness probe until the app has come up
            once. The correct answer for an app whose first boot is slow
            (migrations, an index rebuild) but whose steady state is fast —
            better than inflating the liveness thresholds forever.
          '';
        };
      };

      adopt = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Render this Application with server-side apply and server-side diff,
          for taking over objects that ALREADY EXIST in the cluster — applied
          by an addon, by kubectl, or by a hand-written manifest this
          declaration replaces.

          THE HAZARD THIS EXISTS FOR. A rendered spec is never byte-identical to
          the YAML it replaces: labels differ, fields this grammar sets appear,
          fields it does not set disappear. Argo CD sees a diff and acts on it —
          which for a stateless app is a rollout nobody notices, and for a
          stateful one is downtime, because `state` forces `Recreate`: the old
          pod stops before the new one starts. Server-side apply and diff shrink
          that diff to what genuinely changed instead of a client-side
          reconstruction of it, which is what makes an in-place adoption
          possible at all. It does not make the diff zero. Before flipping a
          live stateful app onto this grammar, render it, diff it against what
          is live, and decide knowingly.
        '';
      };

      raw = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          YAML documents rendered alongside this app's objects and passed
          through: no typed options, no schema defaults injected, no scanning
          (they are re-serialized, so key ORDER is normalized — the content is
          not). THE ESCAPE HATCH, and on purpose — for the objects this
          vocabulary has no term
          for (a wake-front CR, a ConfigMap, an operator's CRD), because a
          grammar that cannot accommodate the awkward case is one people
          abandon at the first awkward case.

          Two things keep it honest rather than a hole. It is VISIBLE: every app
          using it warns at render, and `appPlatform.rawEscapeHatchApps` lists
          them, so "how much of this cluster is still untyped" has a number.
          And it is for WHOLE OBJECTS only — to change a field on something this
          module renders, define it on the object instead
          (`applications.<app>.resources...`), which keeps the change typed and
          checked.
        '';
      };
    };
  });

  ## ---------------------------------------------------------------------
  ## Rendering
  ## ---------------------------------------------------------------------

  # Env from three sources, merged into one attrset keyed by variable name:
  # plain values, and per-key secret references. Collisions are rejected.
  secretKeyEnv = app:
    lib.concatMapAttrs
      (_: sec: lib.mapAttrs
        (_: key: {
          valueFrom.secretKeyRef = { name = sec.secret; inherit key; }
            // lib.optionalAttrs sec.optional { optional = true; };
        })
        sec.env)
      app.secrets;

  containerEnv = app:
    lib.mapAttrs (_: value: { inherit value; }) app.env // secretKeyEnv app;

  envFromSources = app:
    map
      (sec: { secretRef = { name = sec.secret; } // lib.optionalAttrs sec.optional { optional = true; }; })
      (lib.filter (sec: sec.envFrom) (secretEntries app));

  mkProbe = app: probe:
    (if probe.path == null
    then { tcpSocket.port = app.ports.${probe.port}.number; }
    else {
      httpGet = { inherit (probe) path; port = app.ports.${probe.port}.number; };
    })
    // {
      inherit (probe) periodSeconds failureThreshold timeoutSeconds;
    }
    // lib.optionalAttrs (probe.initialDelaySeconds > 0) {
      inherit (probe) initialDelaySeconds;
    };

  volumesOf = app:
    lib.mapAttrs
      (vname: st:
        { name = vname; }
        // (if st.claim != null
        then { persistentVolumeClaim.claimName = st.claim; }
        else { hostPath = { path = st.hostPath; type = st.hostPathType; }; }))
      app.state
    // lib.concatMapAttrs
      (sname: sec: lib.optionalAttrs (sec.mountPath != null) {
        "secret-${sname}" = {
          name = "secret-${sname}";
          secret = { secretName = sec.secret; }
          // lib.optionalAttrs sec.optional { optional = true; };
        };
      })
      app.secrets;

  volumeMountsOf = app:
    lib.mapAttrs
      (vname: st: { name = vname; inherit (st) mountPath; }
      // lib.optionalAttrs st.readOnly { readOnly = true; })
      app.state
    // lib.concatMapAttrs
      (sname: sec: lib.optionalAttrs (sec.mountPath != null) {
        "secret-${sname}" = {
          name = "secret-${sname}";
          inherit (sec) mountPath;
          readOnly = true;
        };
      })
      app.secrets;

  # Empty collections are left UNDEFINED rather than defined-and-empty: nixidy
  # drops a null field but renders `env: []`, and this spine's whole premise is
  # that a human reads and diffs the rendered tree.
  mkContainer = app:
    let
      # A device-plugin resource is integer-only and non-overcommittable, so
      # the request is stated alongside the limit rather than left to be
      # inferred.
      limits = app.resources.limits // gpuLimits app;
      requests = app.resources.requests // gpuLimits app;
      mounts = volumeMountsOf app;
    in
    { image = app.image; }
    // lib.optionalAttrs (containerEnv app != { }) { env = containerEnv app; }
    // lib.optionalAttrs (envFromSources app != [ ]) { envFrom = envFromSources app; }
    // lib.optionalAttrs (app.ports != { }) {
      ports = lib.mapAttrs
        (pname: port: {
          name = pname;
          containerPort = port.number;
          inherit (port) protocol;
        })
        app.ports;
    }
    // lib.optionalAttrs (mounts != { }) { volumeMounts = mounts; }
    // lib.optionalAttrs (app.command != [ ]) { command = app.command; }
    // lib.optionalAttrs (app.args != [ ]) { args = app.args; }
    // lib.optionalAttrs (requests != { } || limits != { }) {
      resources =
        lib.optionalAttrs (requests != { }) { inherit requests; }
        // lib.optionalAttrs (limits != { }) { inherit limits; };
    }
    // lib.optionalAttrs (app.probes.readiness != null) {
      readinessProbe = mkProbe app app.probes.readiness;
    }
    // lib.optionalAttrs (app.probes.liveness != null) {
      livenessProbe = mkProbe app app.probes.liveness;
    }
    // lib.optionalAttrs (app.probes.startup != null) {
      startupProbe = mkProbe app app.probes.startup;
    };

  mkDeployment = app: {
    metadata.labels = labelsOf app;
    spec = {
      # Not rendered at all for a scale-to-zero app: see `scaling`.
      replicas = lib.mkIf (app.scaling == "always") app.replicas;
      strategy.type = if app.state == { } then "RollingUpdate" else "Recreate";
      selector.matchLabels = selectorOf app;
      template = {
        metadata.labels = labelsOf app;
        spec = {
          containers.${app.name} = mkContainer app;
        }
        // lib.optionalAttrs (volumesOf app != { }) { volumes = volumesOf app; }
        # A hostPath-backed app can only run where the path is. Saying so
        # explicitly beats letting the scheduler find that out.
        // lib.optionalAttrs (nodePinned app && platform.hostPathNodeSelector != { }) {
          nodeSelector = platform.hostPathNodeSelector;
        };
      };
    };
  };

  mkService = app: {
    metadata.labels = labelsOf app;
    spec = {
      # ALWAYS ClusterIP. `exposure` is a class, and the front that implements
      # it lives outside the app — a Service type that carries an external
      # address would put a fleet number in a public app declaration.
      type = "ClusterIP";
      selector = selectorOf app;
      ports = lib.mapAttrs
        (pname: port: {
          name = pname;
          port = port.number;
          targetPort = pname;
          inherit (port) protocol;
        })
        app.ports;
    };
  };

  mkNamespace = _app: {
    # LESSON 2, stamped explicitly rather than inherited: a namespace holding
    # live contents that Argo CD reads as no-longer-desired takes everything
    # inside it with it. No option turns this off.
    metadata.annotations."argocd.argoproj.io/sync-options" = "Prune=false";
    metadata.labels."app.kubernetes.io/managed-by" = "nixk3s";
  };

  mkAssertions = app: [
    {
      assertion = !tenancyActive
        || app.project == builtinProject
        || (tenancy.projects ? ${app.project});
      message =
        "app `${app.name}` targets AppProject `${app.project}`, which the tenancy model does not define. "
        + "Add it to `nixk3s.tenancy.projects`, or point the app at a project that exists.";
    }
    {
      # LESSON 1. Not a warning: an Application outside its project's
      # destinations does not sync PARTIALLY, it refuses to sync at all.
      assertion = !tenancyActive
        || app.project == builtinProject
        || !(tenancy.projects ? ${app.project})
        || lib.elem app.namespace tenancy.projects.${app.project}.destinationNamespaces;
      message =
        "app `${app.name}` targets namespace `${app.namespace}`, which is missing from AppProject "
        + "`${app.project}`'s destinations. Argo CD would reject the whole Application with "
        + "InvalidSpecError — including resources already healthy in that namespace. "
        + "Add `${app.namespace}` to `nixk3s.tenancy.projects.${app.project}.destinationNamespaces`.";
    }
    {
      assertion = !app.createNamespace || creatorsOf app.namespace == [ app.name ];
      message =
        "namespace `${app.namespace}` is created by more than one app: "
        + lib.concatStringsSep ", " (creatorsOf app.namespace)
        + ". Two Applications owning one Namespace fight over it; let one app create it, "
        + "or anchor it in the tenancy layer and set `createNamespace = false` on all of them.";
    }
    {
      assertion = lib.all (st: (st.claim == null) != (st.hostPath == null)) (stateEntries app);
      message =
        "app `${app.name}` has a `state` entry backed by neither or both of `claim` and `hostPath`. "
        + "State needs exactly one backing: an existing claim by name, or a path on the node.";
    }
    {
      assertion = lib.all (st: st.claim == null || !(lib.hasInfix "/" st.claim)) (stateEntries app);
      message =
        "app `${app.name}` gives a claim value containing `/`. `state.<name>.claim` is the NAME of an "
        + "existing PersistentVolumeClaim; if you meant a directory on the node, that is `hostPath`.";
    }
    {
      assertion = lib.all (st: st.hostPath == null || lib.hasPrefix "/" st.hostPath) (stateEntries app);
      message = "app `${app.name}` has a `state.<name>.hostPath` that is not absolute.";
    }
    {
      # EXISTS FOR WHAT IT FORCES. `hostPathType` describes a directory on the
      # node, so `volumesOf` reads it on the hostPath side of the backing `if`
      # and nowhere else — which means a claim-backed volume's value was
      # accepted, discarded, and never type-checked. `strayHostPathTypes` reads
      # it for every entry, and the guard that falls out of the reading is real
      # too: a `hostPathType` beside a claim is a fact about a backing this
      # volume does not have, and nothing would ever render it.
      assertion = strayHostPathTypes app == [ ];
      message =
        "app `${app.name}` sets `hostPathType` on claim-backed state ("
        + lib.concatMapStringsSep ", " (n: "`state.${n}`") (strayHostPathTypes app)
        + "). `hostPathType` describes a directory on the NODE; which storage backs a claim is decided "
        + "outside the app, so the value would be dropped rather than honoured. Drop it, or back the "
        + "volume with a `hostPath`.";
    }
    {
      assertion = lib.all (st: lib.hasPrefix "/" st.mountPath) (stateEntries app);
      message = "app `${app.name}` has a `state.<name>.mountPath` that is not absolute.";
    }
    {
      assertion = lib.all (sec: !(lib.hasInfix "/" sec.secret)) (secretEntries app);
      message =
        "app `${app.name}` gives a secret value containing `/`. `secrets.<name>.secret` is the NAME of an "
        + "existing Secret — never a path, and never the content.";
    }
    {
      assertion = lib.all
        (sec: sec.envFrom || sec.env != { } || sec.mountPath != null)
        (secretEntries app);
      message =
        "app `${app.name}` references a Secret without consuming it. Set `envFrom`, name keys in `env`, "
        + "or give a `mountPath` — a reference nothing reads is a typo, not a declaration.";
    }
    {
      assertion = lib.all
        (sec: sec.mountPath == null || lib.hasPrefix "/" sec.mountPath)
        (secretEntries app);
      message = "app `${app.name}` has a `secrets.<name>.mountPath` that is not absolute.";
    }
    {
      assertion = lib.intersectLists (lib.attrNames app.env) (lib.attrNames (secretKeyEnv app)) == [ ];
      message =
        "app `${app.name}` defines these variables both in `env` and from a Secret: "
        + lib.concatStringsSep ", " (lib.intersectLists (lib.attrNames app.env) (lib.attrNames (secretKeyEnv app)))
        + ". One of them would silently win.";
    }
    {
      assertion = lib.all
        (probe: probe == null || (app.ports ? ${probe.port}))
        (lib.attrValues app.probes);
      message =
        "app `${app.name}` probes a port it does not declare in `ports`.";
    }
    {
      assertion = app.exposure == "internal" || app.ports != { };
      message =
        "app `${app.name}` declares exposure `${app.exposure}` but no ports. There is nothing to expose.";
    }
    {
      assertion = app.wake == null || app.scaling == "scale-to-zero";
      message =
        "app `${app.name}` names a wake front but has `scaling = \"always\"`. An always-on app is never "
        + "asleep, so there is nothing to wake.";
    }
    {
      # EXISTS FOR WHAT IT FORCES. `mkDeployment` renders `replicas` behind an
      # `mkIf` on `scaling == "always"`, so on a scale-to-zero app the value is
      # discarded unevaluated and its type is never checked — `replicas = "two"`
      # rendered green. The count is the FIRST term on purpose: that forces it
      # in both modes, so its type stops depending on the render still reading
      # it in the other one.
      #
      # The guard it makes is the mirror of the `wake` one above: a count
      # declared on an app that sleeps is a number nothing will ever render.
      assertion = app.replicas == 1 || app.scaling == "always";
      message =
        "app `${app.name}` declares ${toString app.replicas} replicas but has "
        + "`scaling = \"scale-to-zero\"`. The wake front owns the replica count of a sleeping app — this "
        + "number is not rendered and never reaches the cluster. Drop it, or make the app "
        + "`scaling = \"always\"`.";
    }
    {
      assertion = !(app.gpu && app.scaling == "scale-to-zero") || wakeFrontOf app == "sablier";
      message =
        "app `${app.name}` needs the GPU and scales to zero, so its wake front must be `sablier`: the "
        + "first request has to block until the pod actually holds the device and be answered by the app "
        + "itself, which a front that admits the request earlier cannot do.";
    }
    {
      assertion = !app.gpu || platform.gpuResourceName != null;
      message =
        "app `${app.name}` needs the GPU, but `nixk3s.appPlatform.gpuResourceName` is unset. Name the "
        + "resource your device plugin advertises; guessing it would schedule the pod with no device and "
        + "no error.";
    }
    {
      assertion = offendingStrings app == [ ];
      message =
        "app `${app.name}` contains an address literal in "
        + lib.concatMapStringsSep ", "
          (s: "`${s.where}` (${lib.concatStringsSep ", " (addressLiterals s.value)})")
          (offendingStrings app)
        + ". An app declares needs; addresses are fleet facts and belong to whatever allocates them. "
        + "Reach other services by DNS name, and let the private layer supply anything numeric.";
    }
  ];

  mkWarnings = app: [
    {
      when = !(lib.hasInfix "@sha256:" app.image);
      message =
        "app `${app.name}` uses an unpinned image (`${app.image}`). Two syncs of an identical rendered "
        + "tree can then run different code, which is exactly what this spine exists to prevent.";
    }
    {
      when = nodePinned app && platform.hostPathNodeSelector == { };
      message =
        "app `${app.name}` keeps state on a node path, which pins it to the node holding that path, but "
        + "`nixk3s.appPlatform.hostPathNodeSelector` is unset so nothing says so. On one node this is "
        + "invisible; on two, the app can start on the wrong one against an empty directory.";
    }
    {
      when = nodePinned app && app.scaling == "always" && app.replicas > 1;
      message =
        "app `${app.name}` runs ${toString app.replicas} replicas on node-path state. They share one "
        + "directory with no coordination — which for anything that writes is corruption, not scale.";
    }
    {
      when = app.raw != [ ];
      message =
        "app `${app.name}` passes ${toString (lib.length app.raw)} verbatim manifest(s) through the escape "
        + "hatch. Nothing types or checks those, including the boundary this grammar otherwise enforces.";
    }
  ];

  mkApplication = app: {
    inherit (app) name namespace createNamespace project;

    resources = {
      deployments.${app.name} = mkDeployment app;
      services.${app.name} = lib.mkIf (app.ports != { }) (mkService app);
      namespaces.${app.namespace} = lib.mkIf app.createNamespace (mkNamespace app);
    };

    yamls = app.raw;

    # Adoption of objects something else already applied: server-side apply and
    # diff, so Argo compares against what the API server actually holds.
    syncPolicy.syncOptions.serverSideApply = lib.mkIf app.adopt true;
    compareOptions.serverSideDiff = lib.mkIf app.adopt true;

    # The wake front owns the replica count of a sleeping app; without this,
    # every sync resets it to whatever the manifest says and the app is woken
    # and re-slept by its own GitOps controller.
    ignoreDifferences = lib.mkIf (app.scaling == "scale-to-zero") {
      Deployment = {
        group = "apps";
        name = app.name;
        namespace = app.namespace;
        jsonPointers = [ "/spec/replicas" ];
      };
    };

    assertions = mkAssertions app;
    warnings = mkWarnings app;
  };
in
{
  options.nixk3s.appPlatform = {
    defaultProject = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = ''
        AppProject an app lands in when it does not say otherwise. Matches the
        tenancy module's third tier, where anything that merely runs on the
        cluster belongs.
      '';
    };

    labelPrefix = lib.mkOption {
      type = lib.types.str;
      default = "nixk3s.dev";
      description = ''
        DNS-style prefix for this grammar's own labels (`<prefix>/exposure`,
        `/scaling`, `/wake`, `/gpu`, `/node-pinned`). Override it to a domain
        you control if you would rather not carry this one into your manifests.
      '';
    };

    gpuResourceName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "amd.com/gpu";
      description = ''
        Extended resource your GPU device plugin advertises (`amd.com/gpu`,
        `nvidia.com/gpu`, ...). Deliberately UNSET: an app declares that it
        needs the GPU, while what the cluster calls the device is a cluster
        fact. A wrong guess here is silent — the pod schedules happily with no
        device — so an app with `gpu = true` fails eval until this is named.
      '';
    };

    hostPathNodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''{ "kubernetes.io/hostname" = "the-node-with-the-disks"; }'';
      description = ''
        Node selector stamped on every app whose `state` is backed by a node
        path. Which node that is happens to be a fleet fact, so it is set once,
        privately, instead of appearing in each app.

        Empty by default (a single-node cluster does not need it) and warned
        about per app, because the pin exists whether or not it is written down:
        the path only exists on one node, and a second node turns an implicit
        pin into an app that starts in the wrong place against an empty
        directory.
      '';
    };

    rawEscapeHatchApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.attrNames (lib.filterAttrs (_: app: app.raw != [ ]) enabledApps);
      defaultText = lib.literalExpression "every enabled app with a non-empty `raw`";
      description = ''
        Apps still carrying verbatim manifests through the `raw` escape hatch.
        Read-only, and the point of it is that it is COUNTABLE: an escape hatch
        nobody measures becomes the architecture. A consumer can assert on this
        list to keep the number going down.
      '';
    };
  };

  options.nixk3s.apps = lib.mkOption {
    type = lib.types.attrsOf appType;
    default = { };
    description = ''
      Apps, keyed by name. Each declares WHAT IT NEEDS — an image, ports, an
      exposure class, whether it scales to zero, which existing claims or node
      paths hold its state, which existing Secrets it consumes — and this module
      renders the Argo CD Application, an optional Namespace, a Deployment and
      (when it has ports) a Service.

      The vocabulary is need-shaped: a declaration written against it names
      objects and classes, and takes any fleet fact as a parameter its consumer
      supplies. See the header of this module for the boundary in full, and for
      the two ways out of the grammar when an app needs something it has no term
      for.
    '';
    example = lib.literalExpression ''
      {
        example-app = {
          namespace = "example-apps";
          image = "registry.example.com/example/app:1.2.3@sha256:...";
          ports.http.number = 8080;
          exposure = "public";
          state.data = { claim = "example-app-data"; mountPath = "/data"; };
          secrets.credentials.env.APP_PASSWORD = "password";
          probes.readiness = { port = "http"; path = "/healthz"; };
        };
      }
    '';
  };

  config.applications = lib.mapAttrs (_: mkApplication) enabledApps;
}
