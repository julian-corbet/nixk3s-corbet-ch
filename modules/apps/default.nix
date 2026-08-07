# nixk3s.apps — the app grammar: a shared vocabulary for declaring WHAT AN APP
# NEEDS, from which this module renders the Kubernetes objects.
#
# WHY A GRAMMAR AT ALL. Every hand-written workload module re-implements the
# same scaffolding: an `image`, a `port`, a namespace, then two hundred lines
# hand-building a Deployment and a Service that differ from the next app's in
# about six places. That repetition IS the missing abstraction. Here an app
# declares its needs in a dozen lines and this module renders the rest, so the
# six places that actually differ are the only six things anyone writes.
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
#   An app declares NEEDS. Someone else allocates NUMBERS.
#
# "I need a stable address" is a need; the address is a fleet fact. "I need my
# state to survive a restart" is a need; which storage it lands on is a fleet
# fact. So this option surface has no address, no slot, no octet, no UID/GID,
# no storage path — not as a discouraged field, but as an ABSENT one:
#
#   - `exposure` is a CLASS (`internal` / `nb` / `public`), never an address.
#     Services render `ClusterIP`, always. Nothing here can pin an external IP.
#   - `state` references an EXISTING claim BY NAME. There is no path option, and
#     a claim value containing a `/` fails eval — that is what a storage path
#     looks like when someone tries to smuggle one through a name field.
#   - Free-text values (`image`, `env`, `command`, `args`) are scanned for IP
#     literals and rejected. Container-local addresses (`0.0.0.0`, loopback)
#     are allowed, because those are not facts about anyone's network.
#   - There is deliberately NO generic escape hatch (no `extraPodSpec`, no raw
#     manifest passthrough). One would re-open every hole above. A private
#     overlay that needs a private number sets it on the nixidy resource
#     directly — `applications.<app>.resources...` merges with what this module
#     renders — which keeps the private fact in the private repository where it
#     belongs, instead of in this vocabulary.
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
  # rejection can name the exact field instead of just the app.
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
    // lib.optionalAttrs app.gpu { "${platform.labelPrefix}/gpu" = "true"; };

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
        type = lib.types.str;
        description = ''
          NAME of an existing PersistentVolumeClaim to mount. A name, never a
          path: which storage backs the claim, on which node, from which
          dataset, is a fleet fact allocated privately and deliberately
          unsayable here. A value containing `/` fails eval.

          This grammar never CREATES the claim, and that is the point: the
          claim outlives the app, so its existence is not the app's to declare.
        '';
      };

      mountPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute path INSIDE the container where the claim is mounted. A
          container-internal fact (`/config`, `/data`), not a host path — the
          grammar has no host-path option at all.
        '';
      };

      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount the claim read-only.";
      };
    };
  };

  probeType = lib.types.submodule {
    options = {
      port = lib.mkOption {
        type = lib.types.str;
        description = "Name of one of this app's declared `ports` to probe over HTTP.";
      };

      path = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "HTTP path to GET.";
      };

      initialDelaySeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10;
        description = "Delay before the first probe.";
      };

      periodSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10;
        description = "Interval between probes.";
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
          module's `namespaces`), not whichever workload happened to arrive
          first.

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
          a GitOps tree whose rendered manifests are identical across two
          syncs that produce different running code is a tree that cannot be
          audited. A tag-only image renders fine and warns.
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
          Plain environment variables. PLAIN is the operative word: no secret
          belongs here (a rendered manifest is committed to git in this spine),
          and no address — values are scanned for IP literals and rejected, so
          that a fleet fact cannot enter a public app declaration through the
          one free-text field.
        '';
      };

      ports = lib.mkOption {
        type = lib.types.attrsOf portType;
        default = { };
        description = ''
          Named ports the container listens on. The attribute name is the port
          name used by the Service and by `probe.port`. An app with no ports
          (a worker, a cron-shaped process) renders no Service at all.
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
          the front that implements it (an ingress, a tunnel, an overlay
          route) can select on it and be added without reshaping any app
          declaration. What the class NEVER becomes here is a number: no
          LoadBalancer address, no node port, no hostname. Those are fleet
          facts, allocated where fleet facts belong.
        '';
      };

      scaling = lib.mkOption {
        type = lib.types.enum [ "always" "scale-to-zero" ];
        default = "always";
        description = ''
          `always` — a running replica count this app owns.
          `scale-to-zero` — idles at zero replicas; a wake front brings it up
          on demand. The rendered Deployment then carries NO replica count and
          the Argo CD Application ignores `/spec/replicas`, because the wake
          front owns that field: leave it in the manifest and every sync fights
          the autoscaler over it.
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
          front and this value is not rendered.
        '';
      };

      state = lib.mkOption {
        type = lib.types.attrsOf stateType;
        default = { };
        description = ''
          Persistent state this app NEEDS, keyed by volume name: each entry
          names an EXISTING claim and where to mount it. Declaring any state
          also switches the Deployment to the `Recreate` strategy — a
          single-writer claim plus a rolling update is a deadlock, where the
          new pod waits for a volume the old pod will not release until the new
          one is ready.
        '';
      };

      probe = lib.mkOption {
        type = lib.types.nullOr probeType;
        default = null;
        description = ''
          Optional HTTP readiness probe. Readiness only, on purpose: it gates
          Service endpoints and rollouts, which is what an app-shaped grammar
          can get right. A synthesized LIVENESS probe cannot be — the same
          default that is merely conservative for a web app restart-loops a
          slow-starting one forever. An app that wants one declares it on the
          rendered resource directly.
        '';
      };
    };
  });

  ## ---------------------------------------------------------------------
  ## Rendering
  ## ---------------------------------------------------------------------

  # Empty collections are left UNDEFINED rather than defined-and-empty: nixidy
  # drops a null field but renders `env: []`, and this spine's whole premise is
  # that a human reads and diffs the rendered tree.
  mkContainer = app: {
    image = app.image;
  }
  // lib.optionalAttrs (app.env != { }) {
    env = lib.mapAttrs (_: value: { inherit value; }) app.env;
  }
  // lib.optionalAttrs (app.ports != { }) {
    ports = lib.mapAttrs
      (pname: port: {
        name = pname;
        containerPort = port.number;
        inherit (port) protocol;
      })
      app.ports;
  }
  // lib.optionalAttrs (app.state != { }) {
    volumeMounts = lib.mapAttrs
      (vname: st: { name = vname; inherit (st) mountPath; }
        // lib.optionalAttrs st.readOnly { readOnly = true; })
      app.state;
  }
  // lib.optionalAttrs (app.command != [ ]) { command = app.command; }
  // lib.optionalAttrs (app.args != [ ]) { args = app.args; }
  // lib.optionalAttrs (gpuLimits app != { }) {
    # Requests are set to the same value on purpose: a device plugin resource
    # is integer-only and non-overcommittable, so limit and request must agree.
    resources = { limits = gpuLimits app; requests = gpuLimits app; };
  }
  // lib.optionalAttrs (app.probe != null) {
    readinessProbe = {
      httpGet = {
        inherit (app.probe) path;
        port = app.ports.${app.probe.port}.number;
      };
      inherit (app.probe) initialDelaySeconds periodSeconds;
    };
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
        // lib.optionalAttrs (app.state != { }) {
          volumes = lib.mapAttrs
            (vname: st: {
              name = vname;
              persistentVolumeClaim.claimName = st.claim;
            })
            app.state;
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

  mkNamespace = app: {
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
      assertion = lib.all (st: !(lib.hasInfix "/" st.claim)) (lib.attrValues app.state);
      message =
        "app `${app.name}` gives a claim value containing `/`. `state.<name>.claim` is the NAME of an "
        + "existing PersistentVolumeClaim, never a path — which storage backs it is a fleet fact, "
        + "allocated outside this declaration.";
    }
    {
      assertion = lib.all (st: lib.hasPrefix "/" st.mountPath) (lib.attrValues app.state);
      message = "app `${app.name}` has a `state.<name>.mountPath` that is not absolute.";
    }
    {
      assertion = app.probe == null || (app.ports ? ${app.probe.port});
      message =
        "app `${app.name}` probes port `${lib.optionalString (app.probe != null) app.probe.port}`, "
        + "which it does not declare in `ports`.";
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
  ];

  mkApplication = app: {
    inherit (app) name namespace createNamespace project;

    resources = {
      deployments.${app.name} = mkDeployment app;
      services.${app.name} = lib.mkIf (app.ports != { }) (mkService app);
      namespaces.${app.namespace} = lib.mkIf app.createNamespace (mkNamespace app);
    };

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
        `/scaling`, `/wake`, `/gpu`). Override it to a domain you control if
        you would rather not carry this one into your manifests.
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
  };

  options.nixk3s.apps = lib.mkOption {
    type = lib.types.attrsOf appType;
    default = { };
    description = ''
      Apps, keyed by name. Each declares WHAT IT NEEDS — an image, ports, an
      exposure class, whether it scales to zero, which existing claims hold its
      state — and this module renders the Argo CD Application, an optional
      Namespace, a Deployment and (when it has ports) a Service.

      The vocabulary is deliberately need-shaped and number-free, which is what
      lets it live in a public repository: nothing here can express an address,
      a slot, a UID or a storage path. See the header of this module for the
      boundary in full.
    '';
    example = lib.literalExpression ''
      {
        example-app = {
          namespace = "example-apps";
          image = "registry.example.com/example/app:1.2.3@sha256:...";
          ports.http.number = 8080;
          exposure = "public";
          state.data = { claim = "example-app-data"; mountPath = "/data"; };
        };
      }
    '';
  };

  config.applications = lib.mapAttrs (_: mkApplication) enabledApps;
}
