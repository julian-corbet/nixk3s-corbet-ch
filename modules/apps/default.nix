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
# AN APP IS ONE POD, WHICH MAY HOLD SEVERAL CONTAINERS. `companions` run beside
# the app's own container for the pod's life and `init` containers run to
# completion before it. Neither is a WORKLOAD: nothing here renders a second
# Deployment, a second Service, or any object carrying a `spec.selector`. That
# is the load-bearing half — a selector is IMMUTABLE, so a grammar-generated
# one applied to a live object is a rejected apply and a permanently SyncFailed
# Application, while a pod TEMPLATE is mutable and changing it is a rollout.
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
# against it. Four of those are structurally impossible to write at all:
#
#   - `exposure` is a CLASS (`internal` / `nb` / `public`), never an address.
#     Services render `ClusterIP`, always; nothing here reaches
#     `loadBalancerIP`, `externalIPs` or `nodePort`.
#   - `state.<name>.claim`, `state.<name>.configMap`, `state.<name>.secret` and
#     `secrets.<name>.secret` are NAMES of objects that already exist. A value
#     containing `/` fails eval — that is what a storage path looks like when
#     someone tries to smuggle one through a name field.
#   - `identity` is a ROLE ("this app runs as an unprivileged user"), and WHICH
#     user that is on this fleet lives in `appPlatform.identities`. No uid, gid
#     or fsGroup VALUE can be written on an app.
#   - Free-text values (`image`, `env`, `command`, `args`, on every container in
#     the pod) are scanned for IP literals and rejected. Container-local
#     addresses (`0.0.0.0`, loopback) are allowed, because those are facts
#     about a container, not a network.
#
# A CONTAINER IMAGE IS ALWAYS THE CONSUMER'S VALUE — the app's own and every
# companion's and init container's alike. This module names no image, ever,
# which is exactly what separates a declarable init container from a
# synthesized `dependsOn` wait: the latter would have to CHOOSE an image, and a
# public module naming one is a fleet fact with the serial numbers filed off.
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
#      and the module system merges them. That is how a pinned ClusterIP, a
#      bare wait-for-a-port init container, a `serviceAccountName`, or a
#      pod-spec knob this vocabulary has no term for gets set, without any of
#      it entering the public declaration.
#   2. `raw` — YAML documents passed through with no typing and no schema
#      defaults injected, for whole objects the grammar has no term for at all
#      (a wake-front CR, a ConfigMap). It is deliberately NOT scanned, so it is
#      the one place the boundary stops being enforced: hence every app that
#      uses it warns at render, and `appPlatform.rawEscapeHatchApps` lists them
#      so the number is countable rather than a vague worry. An abstraction
#      people route around is worse than one visible hatch.
#
# WHAT A SIBLING MODULE MUST READ, recorded here because getting it wrong is
# silent: "does this app have an in-cluster address" is `app.rendersService`,
# NOT `app.ports != { }`. Those stopped being the same statement the moment a
# companion could hold the published port and a port could decline to be
# published. There is exactly one authority and this is it.
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

  # The free-text surface of ONE container, paired with where it came from, so
  # a rejection can name the exact field instead of just the app. Every
  # container in the pod has the same four fields, so they are scanned by the
  # same function — a companion that could smuggle an address past a guard
  # which only ever looked at the app's own container would be a hole opened by
  # this extension and left open.
  freeText = prefix: c:
    [{ where = "${prefix}image"; value = imageRegistry c.image; }]
    ++ lib.mapAttrsToList (k: v: { where = "${prefix}env.${k}"; value = v; }) c.env
    ++ lib.imap0 (i: v: { where = "${prefix}command[${toString i}]"; value = v; }) c.command
    ++ lib.imap0 (i: v: { where = "${prefix}args[${toString i}]"; value = v; }) c.args;

  # Every free-text value on one app. `raw` is deliberately absent: see the
  # escape-hatch note in the header.
  scannedStrings = app:
    freeText "" app
    ++ lib.concatLists (lib.mapAttrsToList (cn: c: freeText "companions.${cn}." c) app.companions)
    ++ lib.concatLists (lib.imap0 (i: c: freeText "init[${toString i}]." c) app.init);

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

  # DURABLE means the data outlives the pod, which is the property that decides
  # both the rollout strategy and the node pin. A ConfigMap, a Secret and a
  # scratch directory are none of those things.
  durable = st: st.claim != null || st.hostPath != null;

  backingCount = st: lib.count (b: b) [
    (st.claim != null)
    (st.hostPath != null)
    (st.configMap != null)
    (st.secret != null)
    st.emptyDir
  ];

  # Durable state is the usual reason an app cannot run two live copies, but it
  # is a PROXY. `singleWriter` is the property said directly.
  recreates = app: app.singleWriter || lib.any durable (stateEntries app);

  identityOf = app:
    if app.identity == null || app.identity == "root" then null
    else platform.identities.${app.identity} or null;

  usesEnvIdentity = app: app.identityEnv.user != null || app.identityEnv.group != null;

  wantsFsGroup = app: lib.any (st: st.ownership == "kubelet") (stateEntries app);

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
  # Nothing about multi-container apps reaches this function, and that is
  # structural rather than disciplined: a companion is a pod-template change.
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
    // lib.optionalAttrs (nodePinned app) { "${platform.labelPrefix}/node-pinned" = "true"; }
    // lib.optionalAttrs (app.identity == "root") { "${platform.labelPrefix}/runs-as-root" = "true"; };

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
  ## Derived facts about the POD, now that it may hold more than one container
  ## ---------------------------------------------------------------------

  # Every container that is NOT the app's own. Both kinds share a shape, so
  # everything that is true of a container regardless of when it runs is
  # computed over this one list.
  otherContainers = app: lib.attrValues app.companions ++ app.init;

  containerNames = app:
    [ app.name ] ++ lib.attrNames app.companions ++ map (c: c.name) app.init;

  # Every port any ordinary container of this pod declares. Init containers are
  # excluded structurally: they have no `ports` term at all.
  podPorts = app: app.ports // lib.concatMapAttrs (_: c: c.ports) app.companions;

  # Names claimed twice. `podPorts` MERGES, so a collision would silently
  # resolve to whichever container sorted last — which is why this is computed
  # from the un-merged names and not from `podPorts`.
  duplicatePortNames = app:
    let
      all = lib.attrNames app.ports
        ++ lib.concatMap (c: lib.attrNames c.ports) (lib.attrValues app.companions);
    in
    lib.unique (lib.filter (n: lib.count (m: m == n) all > 1) all);

  publishedPorts = app: lib.filterAttrs (_: p: p.publish) (podPorts app);

  # Every port of the pod UN-MERGED, paired with where it was declared, so a
  # guard can name the field rather than the app — and so that a name claimed
  # twice does not hide one of them from the guard that is looking for it.
  podPortEntries = app:
    lib.mapAttrsToList (pname: p: { where = "ports.${pname}"; inherit p; }) app.ports
    ++ lib.concatLists (lib.mapAttrsToList
      (cn: c: lib.mapAttrsToList
        (pname: p: { where = "companions.${cn}.ports.${pname}"; inherit p; })
        c.ports)
      app.companions);

  # `null` means the app's own container — which is every app that has one, so
  # the term is invisible until a pod grows a second process.
  secretConsumers = app: sec: if sec.containers == null then [ app.name ] else sec.containers;

  # Volumes this app RENDERS, which is what a companion's `mounts` may name:
  # the `state` keys, plus the derived name of every Secret mounted as files.
  secretVolumeNames = app:
    map (n: "secret-${n}")
      (lib.attrNames (lib.filterAttrs (_: sec: sec.mountPath != null) app.secrets));

  declaredVolumes = app: lib.attrNames app.state ++ secretVolumeNames app;

  # A Secret volume has no `state` entry to carry a `readOnly`; the mount's own
  # says everything there is to say about it.
  volumeReadOnlyOf = app: vname: app.state.${vname}.readOnly or false;

  unmountedVolumes = app:
    lib.attrNames (lib.filterAttrs
      (vname: st: st.mountPath == null && st.mounts == [ ]
        && !(lib.any (c: c.mounts ? ${vname}) (otherContainers app)))
      app.state);

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

      servicePort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = ''
          Port the SERVICE publishes, when it differs from the port the
          container listens on. `null` (the default) publishes the container's
          own number, which is right for almost every app and is what this
          grammar has always rendered.

          Still a container/API-side number and never an address: the Service
          is still `ClusterIP`, and nothing here reaches `nodePort`,
          `externalIPs` or `loadBalancerIP`. It exists because "the Service
          always publishes the container's port" was an ASSUMPTION, not a rule
          — an app reached on 80 whose process listens on 8080 currently
          renders a Service nobody can use.

          `targetPort` still renders the port NAME. A live object holding a
          numeric targetPort is an adoption seam, suppressed in the private
          overlay, not a gap in this vocabulary.
        '';
      };

      publish = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the Service publishes this port. `true` (the default) is what
          this grammar has always done for every declared port, and is right for
          every single-process app.

          Set it false for a port that is REAL — a container genuinely listens
          on it and the containerPort belongs in the manifest — but that nothing
          outside the pod should reach: the application socket a co-located web
          server talks to over loopback, a metrics port with no scraper.
          Dropping the port from `ports` instead would be a lie about the
          container; publishing it would be an address the app never asked for,
          and a Service pointed at a FastCGI socket is an app that runs and is
          unreachable.

          An app whose ports ALL go unpublished renders no Service at all,
          exactly like an app with no ports, and is therefore not asked for a
          slot.
        '';
      };
    };
  };

  # WHERE a volume lands inside a container. Split from `state` because a
  # volume and a mount are different things, and real apps mount ONE volume at
  # four to six paths.
  mountType = lib.types.submodule {
    options = {
      mountPath = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute path INSIDE the container for this mount — a
          container-internal fact, exactly like `state.<name>.mountPath`.
        '';
      };

      subPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "config";
        description = ''
          Path WITHIN the volume to mount here, instead of the whole volume.
          Container-internal and RELATIVE by definition: an absolute value, or
          one containing `..`, fails eval — the kubelet refuses both, and an
          absolute one is almost always a `mountPath` written in the wrong
          field.

          This is the term that lets one curated directory appear as the four
          or five places an image insists on, and that drops one key of a
          ConfigMap onto an exact filename instead of mounting a directory over
          the one it lands in.
        '';
      };

      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount read-only. ORed with the volume's own `readOnly`.";
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
          Path on the NODE to mount instead of a claim. The other durable
          backing, and in practice the more common one — most self-hosted apps
          sit on a directory somebody already curates.

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
          outside the app, so setting this beside any other backing fails eval
          instead of being dropped on the way to the manifest.
        '';
      };

      configMap = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          NAME of an existing ConfigMap to mount. A name, never content and
          never a path: a value containing `/` fails eval, exactly as for
          `claim`.

          THIS GRAMMAR NEVER CREATES THE CONFIGMAP, and the refusal is
          deliberate rather than an omission. A ConfigMap's `data` is file
          CONTENT, and content is not vocabulary — a `data` attrset is exactly
          where site configuration would arrive disguised as an app need, and
          the address scan catches literals, not names. Render the object as a
          typed resource on this same Application
          (`applications.<app>.resources.configMaps`, already schema-checked),
          and NAME it here.

          NOT DURABLE: a ConfigMap-backed volume does not make the app a single
          writer, does not force `Recreate`, and does not pin the pod.
        '';
      };

      secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          NAME of an existing Secret to mount AS A VOLUME. A name, never content
          and never a path: a value containing `/` fails eval, exactly as for
          `claim` and `configMap`. Nothing in this vocabulary can express a
          secret's value, and nothing ever will.

          WHY THIS EXISTS BESIDE `secrets.<name>.mountPath`. That term is the
          blunt one and says so: it mounts the WHOLE Secret as a DIRECTORY, one
          file per key, into the app's own container, under a volume whose name
          this grammar derives. The moment the same Secret has to land on ONE
          exact filename — a config overlay dropped beside the app's own config,
          where mounting a directory would cover the directory it lands in — or
          in more than one container, it needs `mounts`, `subPath`, `items` and
          a per-container view: the vocabulary `state` already has. Growing a
          parallel copy of that under `secrets` would be two spellings of one
          concept, and the pod spec would be where they disagreed.

          `secrets.<name>` remains the CONSUMPTION noun (envFrom, named env
          keys, and its whole-directory convenience). `state.<name>` is the
          VOLUME noun, now with five backings.

          NOT DURABLE: a Secret-backed volume does not make the app a single
          writer, does not force `Recreate`, and does not pin the pod.
        '';
      };

      emptyDir = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          A writable scratch directory that lives and dies with the pod — for
          the path an image insists on writing to and nobody wants to keep. It
          is the honest answer to "this has to be writable", where a claim or a
          node path would be a lie about what the data is worth.

          NOT DURABLE: does not force `Recreate` and does not pin the pod.
        '';
      };

      items = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { "app.conf" = "app.conf"; };
        description = ''
          WHICH KEYS of the backing ConfigMap or Secret this volume projects,
          and under WHAT FILENAME, as `<key in the object> = "<relative path in
          the volume>"`. Empty (the default) projects every key under its own
          name.

          Two reasons it is a need and not a knob. It NARROWS: a `subPath` mount
          picks one file out of the volume, but the VOLUME still carries every
          other key, so an unrelated credential ends up readable on a tmpfs
          inside the container, invisibly, because the mount looked narrow. And
          it RENAMES: an image that insists on a filename gets it here instead
          of through a wrapper.

          Still no content: a key is a NAME, and the path is container-internal
          and RELATIVE by definition — an absolute value, or one containing
          `..`, fails eval, exactly like `mountType.subPath`. Rendered as a list
          ordered by key, deterministically, because the kubelet's `items` is a
          list and this grammar emits no positional key.

          For a `configMap` or `secret` backing only. Beside a claim, a node path
          or a scratch directory it describes a projection that backing does not
          have, and fails eval rather than being silently dropped.
        '';
      };

      ownership = lib.mkOption {
        type = lib.types.enum [ "site-curated" "kubelet" ];
        default = "site-curated";
        description = ''
          WHO OWNS THE FILES, which decides whether anything chowns them.

            - `site-curated` (the default) — somebody outside the cluster owns
              this directory and nothing here touches it. No `fsGroup` is
              rendered on account of this volume.
            - `kubelet` — let the kubelet take group ownership, rendering the
              resolved identity's `fsGroup` on the POD securityContext.

          THE DEFAULT IS THE LOAD-BEARING HALF. `fsGroup` makes the kubelet
          RECURSIVELY CHOWN the volume on EVERY pod start. On a claim nothing
          else touches that is merely slow; on a node path somebody curates
          outside the cluster it destroys ownership that was set there
          deliberately. The omission is the default, and asking for it is
          something a person types.

          Only meaningful on a durable backing: asking the kubelet to chown a
          ConfigMap, a Secret or an emptyDir fails eval rather than being
          dropped.
        '';
      };

      mountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute path INSIDE the container where this volume is mounted — the
          single-mount form, and still the one almost every app wants. Leave it
          null and give `mounts` when one volume shows up in several places,
          and leave BOTH null for a volume only a companion or an init
          container reads.
        '';
      };

      mounts = lib.mkOption {
        type = lib.types.listOf mountType;
        default = [ ];
        example = lib.literalExpression ''
          [ { mountPath = "/app/config";  subPath = "config"; }
            { mountPath = "/app/data";    subPath = "data"; }
            { mountPath = "/app/logs";    subPath = "logs"; }
          ]
        '';
        description = ''
          SEVERAL mounts out of this ONE volume, in order, instead of the
          single `mountPath`. At most one of `mountPath` and `mounts` per entry
          — and a volume no container in the pod reads at all fails eval, since
          that is a typo rather than a declaration.

          Declaring N volumes instead is NOT the same pod spec and usually not
          the same app: an image whose data tree is one curated directory wants
          one volume and N views of it, and anything that touches the whole
          tree (an ownership fixup, a backup companion) needs the tree to exist
          as one mount.

          A LIST rather than an attrset because the order is written down here
          and the render keeps it: the first mount takes the volume's own name
          as its key and the rest take a zero-padded ordinal, so the attribute
          sort reproduces exactly what is written and every existing overlay
          keyed on the volume name still lands.
        '';
      };

      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount read-only. ORed with each mount's own `readOnly`.";
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

          The blunt form on purpose: it mounts the WHOLE Secret as a DIRECTORY
          into the app's own container. For one exact filename, a `subPath`, a
          key projection or a view in more than one container, declare the
          Secret as a volume instead — `state.<name>.secret` — which is the
          same vocabulary every other volume already has.
        '';
      };

      containers = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [ "worker" ];
        description = ''
          WHICH CONTAINERS consume this Secret, by name. `null` (the default)
          means the app's OWN container — which is every app that has one, so
          the term is invisible until a pod grows a second process.

          It exists because once a pod has three containers, "which of them gets
          `secrets.db.env.PASSWORD`?" has an answer this grammar must state, and
          stating it only in a docstring while providing no way to change it is
          exactly the half-grammar shape this vocabulary exists to avoid.

          The default is the NARROW one on purpose: a web front in front of an
          application has no business holding the application's database
          credentials, and handing them over because the two share a pod widens
          the blast radius by default. Naming a container the app does not
          declare fails eval — a typo there silently withholds a credential and
          the app fails later, further from the cause.

          The Secret's NAME is stated once and the consumers are a list, rather
          than each container restating the name: the name is the one part that
          genuinely does not differ per consumer, and a second copy of it is a
          second thing to keep in step.

          It governs `envFrom` and `env` only. A `mountPath` here is the app's
          own container by definition; a Secret several containers mount as
          files is `state.<name>.secret`.
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
        description = ''
          Name of one of THIS CONTAINER'S declared `ports` to probe. A probe
          reads a socket through one container's own port table, so naming a
          neighbour's port fails eval rather than rendering a number that
          happens to work and a declaration that lies.
        '';
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

  ## ---------------------------------------------------------------------
  ## Option sets shared by every container in the pod
  ##
  ## Declared ONCE and spliced into the app and into every companion and init
  ## container. Splitting them would let them drift, and a hardening term that
  ## means something different on a companion is worse than none.
  ## ---------------------------------------------------------------------

  # The CONTAINER half of `security`. The POD half — `runAsNonRoot`, `seccomp`
  # — is deliberately NOT here: it is a property of the pod, so it stays on the
  # app and covers every container in it.
  containerSecurityOptions = {
    allowPrivilegeEscalation = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Rendered on the CONTAINER. `false` is the only value this grammar
        accepts; `true` fails eval, because it grants rather than restricts and
        this vocabulary only knows how to restrict.
      '';
    };

    readOnlyRootFilesystem = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Rendered on the CONTAINER. `false` is legal and is NOT the same as
        `null`: an image that must write outside its volumes needs the field
        stated, and a container whose live object does not carry it needs the
        field absent.
      '';
    };

    capabilitiesDrop = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ALL" ];
      description = ''
        Capabilities to drop, rendered as `securityContext.capabilities.drop`
        on the CONTAINER. There is no `add`, here or anywhere: an added
        capability is a hole, and a hole is not something an app grants itself.

        There is likewise no per-container `runAsUser`, and its absence is the
        reason this whole vocabulary can claim to restrict. A container
        securityContext that names a uid the POD does not have is a GRANT
        relative to the pod — it is how an init container becomes root under an
        app that is not. That stays one additive typed-merge line on an object
        this grammar renders.
      '';
    };
  };

  probeOptions = {
    readiness = lib.mkOption {
      type = lib.types.nullOr probeType;
      default = null;
      description = ''
        Readiness probe for THIS container: gates Service endpoints and
        rollouts. Kubernetes holds the pod out of the Service until EVERY
        container is ready, which is why in a pod with a web front it is the
        FRONT's probe that decides when traffic arrives.

        It may only name a port THIS container declares.
      '';
    };

    liveness = lib.mkOption {
      type = lib.types.nullOr probeType;
      default = null;
      description = ''
        Liveness probe for THIS container. NEVER synthesized — a guessed
        liveness probe is the classic way to put a slow-starting app into a
        restart loop that looks like the app's fault. On a companion it
        restarts THAT container only, which is either exactly what you want or
        a restart loop nobody notices in the app's own logs, so it is written
        on purpose or not at all. Same port-ownership rule as `readiness`.
      '';
    };

    startup = lib.mkOption {
      type = lib.types.nullOr probeType;
      default = null;
      description = ''
        Startup probe for THIS container: suspends the liveness probe until it
        has come up once. The correct answer for a container whose first boot
        is slow (migrations, an index rebuild) but whose steady state is fast.
        Same port-ownership rule.
      '';
    };
  };

  resourceOptions = {
    requests = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { cpu = "10m"; memory = "32Mi"; };
      description = ''
        Compute the scheduler must find for THIS container. Per container, not
        per pod, because that is how the scheduler sums them — and a container
        with none is placed as if it were free, which is how a "small" companion
        becomes the reason a node is oversubscribed.
      '';
    };

    limits = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { memory = "256Mi"; };
      description = ''
        Ceilings for THIS container. A memory limit is a kill threshold, which
        is usually what you want for a leaky app; a CPU limit is a throttle,
        which is usually not. A GPU device request (when the app declares
        `gpu`) lands on the app's OWN container only: the card is requested by
        the process that uses it, and a device request spread across a pod's
        containers is two claims on one device.
      '';
    };
  };

  companionType = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.str;
        description = ''
          Container image for this companion. PIN IT BY DIGEST, for the same
          reason the app's own image must be: two syncs of an identical
          rendered tree that run different code is exactly what this spine
          exists to prevent. A tag-only image renders fine and warns — per
          container, so a companion cannot slip an unpinned image past a
          warning that only ever looked at the app's own.

          The VALUE is the consumer's, like every other image reference here.
        '';
      };

      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Entrypoint override for this container. Empty means the image's own. Scanned for address literals exactly like the app's.";
      };

      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Arguments to the entrypoint. Scanned for address literals.";
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Plain environment for THIS container. PLAIN is the operative word,
          exactly as on the app: values are scanned for IP literals and
          rejected, and a secret belongs in the app's `secrets`, which says per
          container who consumes it.

          Reaching a neighbour in the same pod is `localhost`, which the scan
          allows because it is a fact about a container, not about a network.
        '';
      };

      ports = lib.mkOption {
        type = lib.types.attrsOf portType;
        default = { };
        description = ''
          Named ports THIS container listens on — the same `ports` the app has
          always had, on the container that actually holds them.

          The NAME is the pod's, not the container's: Kubernetes requires a
          container port name to be unique across a whole POD, which is exactly
          why a Service can target a companion without naming it —
          `targetPort: <name>` already resolves pod-wide. This grammar CHECKS
          that uniqueness instead of assuming it.

          Whether a port reaches the Service is `ports.<name>.publish`, not
          which container it is on.
        '';
      };

      mounts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf mountType);
        default = { };
        example = lib.literalExpression ''
          { html = [ { mountPath = "/srv/www"; readOnly = true; } ];
            conf = [ { mountPath = "/etc/web/web.conf"; subPath = "web.conf"; } ]; }
        '';
        description = ''
          THIS CONTAINER'S view of the app's volumes, keyed by the volume name
          the app declares in `state` (or `secret-<name>` for a Secret consumed
          through `secrets.<name>.mountPath`). The value is the same `mountType`
          list `state.<name>.mounts` takes, rendered through the same keying
          rule, because a mount is a mount wherever it lands. `readOnly` is ORed
          with the volume's own.

          A VOLUME IS DECLARED ONCE, ON THE APP, AND MOUNTED WHEREVER IT IS
          NEEDED. That split is the point: a volume is a pod fact (it decides
          `Recreate`, it decides the node pin), and a mount is a container fact.
          Three containers sharing one directory genuinely have three different
          mounts of it — read-write here, read-only there, one exact file
          somewhere else — which a per-volume list of container names cannot say
          without repeating the volume once per view.

          Naming a volume the app does not declare fails eval: the kubelet would
          refuse the pod, and this is the cheaper place to find out. A volume no
          container mounts at all also fails eval — it is a typo, not a
          declaration.
        '';
      };

      resources = resourceOptions;
      probes = probeOptions;
      security = containerSecurityOptions;
    };
  };

  initType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = ''
          Name of this init container, unique across every container in the pod.
          Stated rather than derived from a key, because this option is a list —
          and because the name is the merge key a private overlay writes
          against.
        '';
      };

      image = lib.mkOption {
        type = lib.types.str;
        description = "Container image. Pinned by digest, for the same reason as everything else here; the VALUE is the consumer's.";
      };

      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Entrypoint override. Scanned for address literals.";
      };

      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Arguments to the entrypoint. Scanned for address literals.";
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Plain environment, scanned like every other free-text field. A secret belongs in the app's `secrets`, naming this container as a consumer.";
      };

      mounts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf mountType);
        default = { };
        description = "THIS CONTAINER'S view of the app's volumes, keyed by the `state` volume name. Identical in every respect to `companions.<name>.mounts` — same type, same keying, same guards.";
      };

      resources = resourceOptions;
      security = containerSecurityOptions;
    };
  };

  appType = lib.types.submodule ({ name, config, ... }: {
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
        description = "Name of the app, its objects, its own container, and its Argo CD Application.";
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
          Container image for the app's OWN container. PIN IT BY DIGEST
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
          Named ports the app's OWN container listens on. The attribute name is
          the port name used by the Service and by this container's probes, and
          it must be unique across the whole pod. A pod none of whose ports are
          published renders no Service at all.
        '';
      };

      companions = lib.mkOption {
        type = lib.types.attrsOf companionType;
        default = { };
        example = lib.literalExpression ''
          {
            web = {
              image = "registry.example.com/example/web:1.2.3@sha256:...";
              ports.http = { number = 8080; servicePort = 80; };
              mounts.html = [ { mountPath = "/srv/www"; readOnly = true; } ];
              mounts.web-conf = [ { mountPath = "/etc/web/web.conf"; subPath = "web.conf"; } ];
              probes.readiness = { port = "http"; path = "/healthz"; };
            };
          }
        '';
        description = ''
          Other containers in THIS APP'S POD, running beside the app's own for
          the pod's whole life. Keyed by container name.

          A COMPANION IS NOT A WORKLOAD, and cannot become one. Nothing here
          renders a second Deployment, a second Service, or any object carrying
          a `spec.selector`. That matters more than it sounds: a selector is
          IMMUTABLE, so a grammar-generated one applied to a live object is a
          rejected apply and a permanently SyncFailed Application, not a
          rollout. A companion is a change to a pod TEMPLATE, which is mutable,
          which is what a rollout is.

          THE APP IS STILL ITS OWN CONTAINER. `image`, `command`, `args`, `env`,
          `ports`, `probes`, `resources`, `security`, `state`, `secrets`,
          `identity` and `gpu` at the app level keep meaning exactly what they
          mean with no companions declared, and describe the app's own
          container. A companion states the same kinds of thing about itself,
          in the same words, and nothing else.

          WHAT A POD IS FOR, so this does not become the place two applications
          get stapled together: containers in one pod share a network
          namespace, share volumes, and start, stop and move as one unit. That
          is right for a web front in front of an application, a push service
          reading the application's own directory, a metrics exporter. It is
          wrong for a cache, a database or a queue — those restart and scale on
          their own schedule, they are separate workloads that happen to be used
          by this one, and they belong on their own objects as typed resources
          on this same Application.

          WHAT A COMPANION MAY NOT DECLARE, and why: no `gpu` (the device is
          claimed once, by the process that uses it), no `identity` (an identity
          is a POD property here — per-container uids are how two containers
          sharing one volume end up unable to read each other's files, and a
          container uid the pod does not have is a grant), no `state` (a volume
          belongs to the pod, so it is declared on the app and MOUNTED here),
          and no `exposure`, `scaling`, `replicas` or `adopt` (properties of a
          workload, and a companion is not one).

          ORDER IS THE ATTRIBUTE SORT, and is deliberately not a term. Position
          carries no meaning to Kubernetes for a container that runs for the
          pod's life, so reproducing a hand-written order is an ADOPTION
          artifact with a known end date, exactly like `env` order. Declaring a
          companion on a live app therefore reorders its container list unless
          the live order happens to be alphabetical — which for a `Recreate` app
          is a stop-then-start for no behaviour change. Render it, diff it, and
          pin the order in the private overlay before the first sync. (`init` is
          the opposite case and IS ordered — see there.)
        '';
      };

      init = lib.mkOption {
        type = lib.types.listOf initType;
        default = [ ];
        example = lib.literalExpression ''
          [ { name = "assert-config";
              image = "registry.example.com/example/app:1.2.3@sha256:...";
              command = [ "sh" "-c" ];
              args = [ "test -s /cfg/identity || exit 1" ];
              mounts.cfg = [ { mountPath = "/cfg/identity"; subPath = "identity"; readOnly = true; } ];
            } ]
        '';
        description = ''
          Containers that must run to completion, IN THIS ORDER, before any of
          the app's containers start.

          A LIST, not an attrset, and that is the whole reason this is a term
          rather than a typed-merge line. Init order is SEMANTIC — the kubelet
          runs them one after another — while an attrset-keyed list renders in
          ATTRIBUTE-NAME order unless every element carries an internal priority
          field. So an attrset-shaped init term silently reverses any sequence
          that is not alphabetical. The render turns this list into the schema's
          own list form, which stamps the positions and keeps each container's
          plain NAME as its merge key, so a private overlay that also defines
          that container merges with it rather than adding a duplicate.

          THE CASE THIS EXISTS FOR is NOT "wait for the database". A bare wait —
          a tiny image, a loop on a TCP port, no volumes, no secrets — is
          genuinely nothing this grammar owns, and it should stay the
          typed-merge line the module header names it as. This term exists for
          the OTHER kind: an init container that mounts the app's OWN volumes or
          runs the app's OWN image. A guard that refuses to start when a
          credential is missing, a fixup that walks the whole data tree, a
          first-boot seed. Written in an overlay those restate, by hand, a mount
          key this grammar mints and an image string this grammar already holds
          — which is a second copy nothing keeps in step, and a mount that
          silently stops landing the day the volume is renamed.

          AN INIT CONTAINER DECLARES NO PORTS AND NO PROBES, and they are not in
          the type: the API server rejects a readiness probe on a non-restartable
          init container, and a port on a process that has already exited is a
          fact about nothing.

          ADOPTING THIS TERM MEANS MOVING ALL OF THE APP'S INIT CONTAINERS INTO
          IT, in the same commit. The grammar cannot see a private
          `initContainers` overlay, and one left behind does not append — it
          lands at its own alphabetical position among the grammar's ordered
          ones and interleaves.

          There is deliberately no `dependsOn`. It would have to SYNTHESIZE a
          container, which means a public module choosing an image; the wait
          semantics genuinely differ per app; and a term that only knows how to
          wait on a TCP port is one people route around at the first awkward
          case. An init container's image is a parameter, and that is the
          difference.
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
          This app claims the shared GPU. Two consequences: the app's OWN
          container requests one device (`nixk3s.appPlatform.gpuResourceName`,
          which the operator must name — nothing is guessed), and a
          scale-to-zero GPU app is fronted by `sablier`, not `keda`.

          The reason for that second one is the device, not the protocol: a
          request that arrives while the app is down must BLOCK until the pod
          actually holds the card, and be answered by the app itself. A front
          that admits the request earlier turns "the GPU is busy" into a
          five-hundred at the edge.

          The device request lands on the app's own container and nowhere else.
          A card requested twice in one pod is two claims on one device.
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

      singleWriter = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Two live copies of this app at once are a hazard, so it takes
          `Recreate` even though it declares no durable `state` here.

          Durable state is the usual reason and is still derived
          automatically; it is a PROXY for the real property, and this is the
          real property said directly — for an app whose single-writer resource
          is somebody else's (a schema it migrates on every boot) or is inside
          its own process (an editing session the second copy has never seen).

          It can only ever ADD serialization. There is deliberately no term for
          the other direction: forcing `RollingUpdate` onto an app with a
          single-writer volume is the deadlock the derivation exists to
          prevent, where the new pod waits for a volume the old pod will not
          release until the new one is ready.
        '';
      };

      identity = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "unprivileged-app";
        description = ''
          WHICH IDENTITY this app runs as, named as a ROLE — never as a number.
          "This app runs as an unprivileged user" is a fact about the app;
          WHICH unprivileged user is a fact about the fleet, so the app names
          the role and `nixk3s.appPlatform.identities` says what the role IS.
          Naming a role the site has not defined fails eval, exactly like
          `gpuResourceName`: an identity silently dropped is a pod running as
          root with nothing in the tree saying so.

          IT IS A POD PROPERTY, covering every container in the pod. There is no
          per-container identity: two containers sharing one volume under
          different uids is how they end up unable to read each other's files,
          and a container uid the pod does not have is a GRANT rather than a
          restriction.

          `"root"` is RESERVED and resolves to nothing. It is how an app whose
          image must start as uid 0 says so OUT LOUD — the rendered objects
          then carry a `<prefix>/runs-as-root` label, so the exception is
          countable instead of a comment somebody eventually deletes. The
          registry may not define a role of that name.

          `null` (the default) renders no identity at all, for an app that has
          no opinion.

          ADOPTING THIS TERM MEANS DELETING the app's private securityContext
          overlay in the SAME commit. Two definers of one path is a merge
          conflict at best and a silent winner at worst.
        '';
      };

      identityEnv = {
        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "PUID";
          description = ''
            NAME of the environment variable this image reads its user id from,
            for the very common family that starts as root, chowns its own
            config and drops privileges itself.

            The variable NAME is a fact about the IMAGE and is public. The
            NUMBER it carries comes from the same registry entry `identity`
            names, so there is still exactly one numeric authority and an app
            never restates a uid in order to change spelling.

            Setting it means the identity is delivered as ENVIRONMENT INSTEAD
            OF as a securityContext: `runAsUser` is then not rendered, because
            an image that must start as root cannot also be told not to.
          '';
        };

        group = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "PGID";
          description = "As `identityEnv.user`, for the group id.";
        };
      };

      # EVERY TERM HERE RESTRICTS. There is no `privileged`, no
      # `capabilities.add`, no `hostNetwork`, no `hostPID` and there will not
      # be: those GRANT, and what a cluster grants is not something an app
      # declares. An app that genuinely needs one keeps a private overlay line,
      # where somebody has to type it on purpose and a reader can count them.
      #
      # Every field is TRI-STATE. `null` means this grammar says nothing and
      # the field is absent from the manifest — which is what lets an app
      # reproduce exactly the subset its live object already carries, instead
      # of being handed a bundle it then has to force off.
      security = containerSecurityOptions // {
        runAsNonRoot = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
          description = ''
            Refuse to start if the effective user is 0. Rendered on the POD.
            Needs an identity the kubelet can check, or an image whose own USER
            is numeric and non-zero — set it with no `identity` and the pod is
            rejected at admission, which is why that combination warns.
          '';
        };

        seccomp = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum [ "RuntimeDefault" "Unconfined" ]);
          default = null;
          description = ''
            Seccomp profile, rendered as `securityContext.seccompProfile.type`
            on the POD. `Localhost` is deliberately absent from the enum: it
            names a profile FILE ON THE NODE, which is a fleet fact wearing an
            enum's clothes.
          '';
        };
      };

      resources = resourceOptions;

      state = lib.mkOption {
        type = lib.types.attrsOf stateType;
        default = { };
        description = ''
          Volumes this app NEEDS, keyed by volume name. Each entry has exactly
          ONE of five backings — an existing claim (`claim`), a path on the node
          (`hostPath`), an existing ConfigMap (`configMap`), an existing Secret
          (`secret`), or a scratch directory (`emptyDir`). None of them is
          created here.

          Two of those five are DURABLE — the claim and the node path — and only
          those switch the Deployment to the `Recreate` strategy, because a
          single-writer volume plus a rolling update is a deadlock where the new
          pod waits for a volume the old pod will not release until the new one
          is ready. An app that is a single writer for some other reason says so
          with `singleWriter`.

          A VOLUME IS DECLARED ONCE HERE AND MOUNTED WHEREVER IT IS NEEDED:
          `mountPath` or `mounts` for the app's own container, and
          `companions.<name>.mounts` / `init[].mounts` for the rest. A volume no
          container in the pod reads is a typo, and fails eval.
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
          typo, not a declaration. `containers` says WHICH containers of the pod
          the environment forms reach; by default, the app's own.

          The app names a Secret; it never carries the content. Nothing in this
          vocabulary can express a secret's value, so a declaration is safe to
          publish even when the Secret it names is not.
        '';
      };

      probes = probeOptions;

      rendersService = lib.mkOption {
        type = lib.types.bool;
        readOnly = true;
        default = lib.any (p: p.publish)
          (lib.attrValues (config.ports
            // lib.concatMapAttrs (_: c: c.ports) config.companions));
        defaultText = lib.literalExpression "whether any container publishes a port";
        description = ''
          Whether this app renders a Service. Read-only, and it exists so that
          the question has exactly ONE authority.

          "An app with ports" stopped being the same statement as "an app with
          an address" the moment a companion could hold the published port and
          a port could decline to be published. A sibling module that needs to
          know whether an app has an in-cluster address must read THIS rather
          than re-deriving it from `ports` — two derivations of one fact in two
          modules is a fact that drifts, and this one gates a slot.
        '';
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
          stateful one is downtime, because durable `state` forces `Recreate`:
          the old pod stops before the new one starts. Server-side apply and
          diff shrink that diff to what genuinely changed instead of a
          client-side reconstruction of it, which is what makes an in-place
          adoption possible at all. It does not make the diff zero. Before
          flipping a live stateful app onto this grammar, render it, diff it
          against what is live, and decide knowingly.
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
          checked. A second WORKLOAD is a whole object; a second CONTAINER is
          not, and has terms of its own (`companions`, `init`).
        '';
      };
    };
  });

  ## ---------------------------------------------------------------------
  ## Rendering
  ## ---------------------------------------------------------------------

  # Env from three sources, merged into one attrset keyed by variable name:
  # plain values, the identity's own spelling, and per-key secret references.
  # Collisions are rejected rather than resolved, so the merge order carries no
  # meaning.
  secretKeyEnv = app: cname:
    lib.concatMapAttrs
      (_: sec: lib.optionalAttrs (lib.elem cname (secretConsumers app sec))
        (lib.mapAttrs
          (_: key: {
            valueFrom.secretKeyRef = { name = sec.secret; inherit key; }
              // lib.optionalAttrs sec.optional { optional = true; };
          })
          sec.env))
      app.secrets;

  identityEnvOf = app:
    let id = identityOf app; in
    lib.optionalAttrs (id != null && app.identityEnv.user != null)
      { ${app.identityEnv.user} = { value = toString id.uid; }; }
    // lib.optionalAttrs (id != null && app.identityEnv.group != null)
      { ${app.identityEnv.group} = { value = toString id.gid; }; };

  containerEnv = app: cname:
    lib.mapAttrs (_: value: { inherit value; }) app.env
    // identityEnvOf app
    // secretKeyEnv app cname;

  envFromSources = app: cname:
    map
      (sec: { secretRef = { name = sec.secret; } // lib.optionalAttrs sec.optional { optional = true; }; })
      (lib.filter (sec: sec.envFrom && lib.elem cname (secretConsumers app sec)) (secretEntries app));

  podSecurityOf = app:
    let id = identityOf app; s = app.security; in
    lib.optionalAttrs (id != null && !(usesEnvIdentity app))
      { runAsUser = id.uid; runAsGroup = id.gid; }
    # THE RULE, once: the kubelet recursively chowns an fsGroup volume on every
    # pod start, so it is rendered only where a volume ASKED for it.
    // lib.optionalAttrs (id != null && wantsFsGroup app) { inherit (id) fsGroup; }
    // lib.optionalAttrs (s.runAsNonRoot != null) { inherit (s) runAsNonRoot; }
    // lib.optionalAttrs (s.seccomp != null) { seccompProfile.type = s.seccomp; };

  # Takes the security attrset, not the app: every container in the pod has the
  # same three container-level fields and they mean the same thing on each.
  containerSecurityOf = s:
    lib.optionalAttrs (s.allowPrivilegeEscalation != null) { inherit (s) allowPrivilegeEscalation; }
    // lib.optionalAttrs (s.readOnlyRootFilesystem != null) { inherit (s) readOnlyRootFilesystem; }
    // lib.optionalAttrs (s.capabilitiesDrop != [ ]) { capabilities.drop = s.capabilitiesDrop; };

  # Takes the PORT SET, not the app: probe ports are container-local in
  # Kubernetes, and resolving them against the app was correct only while there
  # was one container.
  mkProbe = ports: probe:
    (if probe.path == null
    then { tcpSocket.port = ports.${probe.port}.number; }
    else {
      httpGet = { inherit (probe) path; port = ports.${probe.port}.number; };
    })
    // {
      inherit (probe) periodSeconds failureThreshold timeoutSeconds;
    }
    // lib.optionalAttrs (probe.initialDelaySeconds > 0) {
      inherit (probe) initialDelaySeconds;
    };

  # A list ordered by key, so the rendered order is deterministic without this
  # module emitting any positional key of its own.
  itemsOf = st: lib.optionalAttrs (st.items != { })
    { items = lib.mapAttrsToList (key: path: { inherit key path; }) st.items; };

  volumesOf = app:
    lib.mapAttrs
      (vname: st:
        { name = vname; }
        // (if st.claim != null
        then { persistentVolumeClaim.claimName = st.claim; }
        else if st.hostPath != null
        then { hostPath = { path = st.hostPath; type = st.hostPathType; }; }
        else if st.configMap != null
        then { configMap = { name = st.configMap; } // itemsOf st; }
        else if st.secret != null
        then { secret = { secretName = st.secret; } // itemsOf st; }
        else { emptyDir = { }; }))
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

  # ONE keying rule for every mount in the pod. The KEY is what every private
  # overlay pins against, so it must NOT depend on which container is being
  # rendered: the first mount of a volume takes the volume's own name, the rest
  # take a zero-padded ordinal. `volumeMounts` merges on `mountPath` while this
  # grammar keys by VOLUME NAME, so a list definition would land under a second
  # key and mount the same path twice.
  mountAttrs = vname: volumeReadOnly: ms:
    lib.listToAttrs (lib.imap0
      (i: m:
        lib.nameValuePair
          (if i == 0 then vname else "${vname}-${lib.fixedWidthNumber 2 i}")
          ({ name = vname; inherit (m) mountPath; }
            // lib.optionalAttrs (m.subPath != null) { inherit (m) subPath; }
            // lib.optionalAttrs (volumeReadOnly || m.readOnly) { readOnly = true; }))
      ms);

  # The app's OWN container's view, read off `state` — where it has always
  # been. `mountPath` is the single-mount shorthand and reduces to a
  # one-element list.
  primaryMountsOf = app:
    lib.concatMapAttrs
      (vname: st: mountAttrs vname st.readOnly
        (if st.mounts != [ ] then st.mounts
        else
          lib.optional (st.mountPath != null)
            { mountPath = st.mountPath; subPath = null; readOnly = false; }))
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

  otherMountsOf = app: c:
    lib.concatMapAttrs (vname: ms: mountAttrs vname (volumeReadOnlyOf app vname) ms) c.mounts;

  # Every container of the pod, paired with its own mount attrset — the shape
  # the per-container mount guards are computed over.
  containerMountViews = app:
    [{ cname = app.name; mounts = primaryMountsOf app; }]
    ++ lib.mapAttrsToList (cname: c: { inherit cname; mounts = otherMountsOf app c; }) app.companions
    ++ map (c: { cname = c.name; mounts = otherMountsOf app c; }) app.init;

  # Empty collections are left UNDEFINED rather than defined-and-empty: nixidy
  # drops a null field but renders `env: []`, and this spine's whole premise is
  # that a human reads and diffs the rendered tree.
  #
  # ONE renderer, three callers. It takes a normalized VIEW rather than the
  # app, and every field of the app's own view is the expression that was
  # inline before companions existed.
  mkContainer = view:
    { image = view.image; }
    // lib.optionalAttrs (view.env != { }) { env = view.env; }
    // lib.optionalAttrs (view.envFrom != [ ]) { envFrom = view.envFrom; }
    // lib.optionalAttrs (view.ports != { }) {
      ports = lib.mapAttrs
        (pname: port: {
          name = pname;
          containerPort = port.number;
          inherit (port) protocol;
        })
        view.ports;
    }
    // lib.optionalAttrs (view.mounts != { }) { volumeMounts = view.mounts; }
    // lib.optionalAttrs (view.command != [ ]) { command = view.command; }
    // lib.optionalAttrs (view.args != [ ]) { args = view.args; }
    // lib.optionalAttrs (view.requests != { } || view.limits != { }) {
      resources =
        lib.optionalAttrs (view.requests != { }) { inherit (view) requests; }
        // lib.optionalAttrs (view.limits != { }) { inherit (view) limits; };
    }
    // lib.optionalAttrs (view.security != { }) { securityContext = view.security; }
    // lib.optionalAttrs (view.probes.readiness != null) {
      readinessProbe = mkProbe view.ports view.probes.readiness;
    }
    // lib.optionalAttrs (view.probes.liveness != null) {
      livenessProbe = mkProbe view.ports view.probes.liveness;
    }
    // lib.optionalAttrs (view.probes.startup != null) {
      startupProbe = mkProbe view.ports view.probes.startup;
    };

  noProbes = { readiness = null; liveness = null; startup = null; };

  primaryView = app: {
    inherit (app) image command args ports;
    env = containerEnv app app.name;
    envFrom = envFromSources app app.name;
    mounts = primaryMountsOf app;
    # A device-plugin resource is integer-only and non-overcommittable, so the
    # request is stated alongside the limit rather than left to be inferred.
    requests = app.resources.requests // gpuLimits app;
    limits = app.resources.limits // gpuLimits app;
    security = containerSecurityOf app.security;
    probes = app.probes;
  };

  otherView = app: cname: c: {
    inherit (c) image command args;
    # An init container has no `ports` and no `probes` term at all.
    ports = c.ports or { };
    env = lib.mapAttrs (_: value: { inherit value; }) c.env // secretKeyEnv app cname;
    envFrom = envFromSources app cname;
    mounts = otherMountsOf app c;
    # Never `gpuLimits`: the device is the app's own container's.
    requests = c.resources.requests;
    limits = c.resources.limits;
    security = containerSecurityOf c.security;
    probes = c.probes or noProbes;
  };

  mkDeployment = app: {
    metadata.labels = labelsOf app;
    spec = {
      # Not rendered at all for a scale-to-zero app: see `scaling`.
      replicas = lib.mkIf (app.scaling == "always") app.replicas;
      strategy.type = if recreates app then "Recreate" else "RollingUpdate";
      selector.matchLabels = selectorOf app;
      template = {
        metadata.labels = labelsOf app;
        spec = {
          # The app's own container keeps the key `${app.name}` unconditionally
          # and forever: that key is what every private overlay writes against.
          containers = { ${app.name} = mkContainer (primaryView app); }
            // lib.mapAttrs (cname: c: mkContainer (otherView app cname c)) app.companions;
        }
        # A LIST, in WRITTEN order, because the kubelet runs init containers in
        # list order. The schema's list form keys each element by its `name` and
        # stamps the position, so the order is ours and the merge key stays the
        # container's plain name — which is what a private overlay writes
        # against. This module still writes no priority of its own and depends
        # on no attribute sort.
        #
        # It MUST stay behind `optionalAttrs`: nixidy drops a null field but
        # renders an empty list, so an unconditional definition would print
        # `initContainers: []` on every app that has none.
        // lib.optionalAttrs (app.init != [ ]) {
          initContainers =
            map (c: mkContainer (otherView app c.name c) // { inherit (c) name; }) app.init;
        }
        // lib.optionalAttrs (podSecurityOf app != { }) { securityContext = podSecurityOf app; }
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
      # `targetPort` is the port NAME, which Kubernetes resolves pod-wide —
      # which is exactly why a Service can target a companion's port with no
      # cross-reference and, decisively, with no change to `spec.selector`.
      ports = lib.mapAttrs
        (pname: port: {
          name = pname;
          port = if port.servicePort != null then port.servicePort else port.number;
          targetPort = pname;
          inherit (port) protocol;
        })
        (publishedPorts app);
    };
  };

  mkNamespace = _app: {
    # LESSON 2, stamped explicitly rather than inherited: a namespace holding
    # live contents that Argo CD reads as no-longer-desired takes everything
    # inside it with it. No option turns this off.
    metadata.annotations."argocd.argoproj.io/sync-options" = "Prune=false";
    metadata.labels."app.kubernetes.io/managed-by" = "nixk3s";
  };

  ## ---------------------------------------------------------------------
  ## Guards
  ## ---------------------------------------------------------------------

  relativeAndClean = p: !(lib.hasPrefix "/" p) && !(lib.hasInfix ".." p);

  # Mounts of one container that land on the same path. `volumeMounts` merges
  # on `mountPath`, so one of them is invisible and which one depends on the
  # emission order.
  duplicateMountPaths = ms:
    let ps = map (m: m.mountPath) (lib.attrValues ms); in
    lib.unique (lib.filter (p: lib.count (q: q == p) ps > 1) ps);

  # A mount whose path lies UNDER another mount's path, emitted BEFORE it: the
  # later, shallower mount covers the earlier one and its contents are
  # invisible to the process. Emission order is the attribute sort, which is
  # what `lib.attrValues` reproduces.
  shadowedMounts = ms:
    let ps = map (m: m.mountPath) (lib.attrValues ms); in
    lib.concatLists (lib.imap0
      (i: child: lib.concatLists (lib.imap0
        (j: parent:
          lib.optional (j > i && parent != child && lib.hasPrefix "${parent}/" child)
            "`${child}` under `${parent}`")
        ps))
      ps);

  # State keys whose ordinal form would collide with another key: a volume
  # named `data` with three mounts mints `data-01` and `data-02`, so a
  # second volume literally named `data-01` silently loses one of them.
  collidingStateKeys = app:
    let names = lib.attrNames app.state; in
    lib.filter
      (n: lib.any (m: builtins.match "${n}-[0-9][0-9]" m != null) names)
      names;

  # Container-level `security` of every container in the pod, named, so a
  # violation can say which container carries it.
  containerSecurities = app:
    [{ cname = app.name; inherit (app) security; }]
    ++ lib.mapAttrsToList (cname: c: { inherit cname; inherit (c) security; }) app.companions
    ++ map (c: { cname = c.name; inherit (c) security; }) app.init;

  # Every mount record any non-primary container declares, flattened, for the
  # path guards. The app's own mounts are guarded through `state` itself.
  otherMountRecords = app:
    lib.concatLists (map (c: lib.concatLists (lib.attrValues c.mounts)) (otherContainers app));

  # Volume names a companion or init container mounts that this app does not
  # render at all.
  undeclaredMountKeys = app:
    let declared = declaredVolumes app; in
    lib.unique (lib.concatMap
      (c: lib.filter (v: !(lib.elem v declared)) (lib.attrNames c.mounts))
      (otherContainers app));

  # Secret consumers naming a container the app does not declare.
  unknownSecretConsumers = app:
    let known = containerNames app; in
    lib.unique (lib.concatLists (lib.mapAttrsToList
      (_: sec: lib.filter (c: !(lib.elem c known))
        (if sec.containers == null then [ ] else sec.containers))
      app.secrets));

  # Probes naming a port their OWN container does not declare.
  strayProbePorts = app:
    let
      check = prefix: ports: probes:
        lib.filter (x: x != null) (lib.mapAttrsToList
          (pn: probe: if probe != null && !(ports ? ${probe.port}) then "${prefix}${pn}" else null)
          probes);
    in
    check "probes." app.ports app.probes
    ++ lib.concatLists (lib.mapAttrsToList
      (cn: c: check "companions.${cn}.probes." c.ports c.probes)
      app.companions);

  # One variable defined twice on one container: whichever wins, it is not what
  # was meant.
  envCollisions = app:
    let
      collide = cname: plain: lib.intersectLists (lib.attrNames plain) (lib.attrNames (secretKeyEnv app cname));
    in
    collide app.name app.env
    ++ lib.concatLists (lib.mapAttrsToList (cn: c: collide cn c.env) app.companions)
    ++ lib.concatLists (map (c: collide c.name c.env) app.init);

  identityEnvNames = app:
    lib.filter (n: n != null) [ app.identityEnv.user app.identityEnv.group ];

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
      # A1. Five backings now, and still exactly one per volume.
      assertion = lib.all (st: backingCount st == 1) (stateEntries app);
      message =
        "app `${app.name}` has a `state` entry backed by none or several of `claim`, `hostPath`, "
        + "`configMap`, `secret` and `emptyDir`. A volume needs exactly one backing: two is two "
        + "volumes wearing one name, and none is not storage.";
    }
    {
      assertion = lib.all (st: st.claim == null || !(lib.hasInfix "/" st.claim)) (stateEntries app);
      message =
        "app `${app.name}` gives a claim value containing `/`. `state.<name>.claim` is the NAME of an "
        + "existing PersistentVolumeClaim; if you meant a directory on the node, that is `hostPath`.";
    }
    {
      # A2 and C7's second half: two more name fields, the same rule.
      assertion = lib.all
        (st: (st.configMap == null || !(lib.hasInfix "/" st.configMap))
          && (st.secret == null || !(lib.hasInfix "/" st.secret)))
        (stateEntries app);
      message =
        "app `${app.name}` gives a `state.<name>.configMap` or `state.<name>.secret` containing `/`. "
        + "Both are NAMES of objects that already exist — never a path, and never the content. A path "
        + "inside the container is `mountPath`; a path on the node is `hostPath`.";
    }
    {
      assertion = lib.all (st: st.hostPath == null || lib.hasPrefix "/" st.hostPath) (stateEntries app);
      message = "app `${app.name}` has a `state.<name>.hostPath` that is not absolute.";
    }
    {
      # EXISTS FOR WHAT IT FORCES. `hostPathType` describes a directory on the
      # node, so `volumesOf` reads it on the hostPath side of the backing chain
      # and nowhere else — which means a volume backed any other way had its
      # value accepted, discarded, and never type-checked.
      # `strayHostPathTypes` reads it for every entry, and the guard that falls
      # out of the reading is real too: a `hostPathType` beside a claim is a
      # fact about a backing this volume does not have.
      assertion = strayHostPathTypes app == [ ];
      message =
        "app `${app.name}` sets `hostPathType` on state that is not backed by a node path ("
        + lib.concatMapStringsSep ", " (n: "`state.${n}`") (strayHostPathTypes app)
        + "). `hostPathType` describes a directory on the NODE; every other backing is decided "
        + "elsewhere, so the value would be dropped rather than honoured. Drop it, or back the "
        + "volume with a `hostPath`.";
    }
    {
      # A3, widened by companions: "neither" is legal for a volume only another
      # container mounts, and the guard that a volume must be READ by somebody
      # is the next assertion.
      assertion = lib.all (st: !(st.mountPath != null && st.mounts != [ ])) (stateEntries app);
      message =
        "app `${app.name}` gives both `mountPath` and `mounts` on one `state` entry. `mountPath` is the "
        + "single-mount shorthand for exactly what `mounts` says at length; giving both is two answers "
        + "to one question.";
    }
    {
      # C4. Only reachable now that `mountPath` may be null.
      assertion = unmountedVolumes app == [ ];
      message =
        "app `${app.name}` declares state no container in the pod mounts ("
        + lib.concatMapStringsSep ", " (n: "`state.${n}`") (unmountedVolumes app)
        + "). Give it a `mountPath`, a `mounts` list, or a view on a companion or init container — a "
        + "volume nothing reads is a typo, not a declaration.";
    }
    {
      assertion = lib.all (st: st.mountPath == null || lib.hasPrefix "/" st.mountPath) (stateEntries app);
      message = "app `${app.name}` has a `state.<name>.mountPath` that is not absolute.";
    }
    {
      # A4 and C9's first half.
      assertion = lib.all (m: lib.hasPrefix "/" m.mountPath)
        (lib.concatMap (st: st.mounts) (stateEntries app) ++ otherMountRecords app);
      message =
        "app `${app.name}` has a mount whose `mountPath` is not absolute. A mount path is a "
        + "container-internal absolute path, and the kubelet rejects anything else at admission.";
    }
    {
      # A5 and C9's second half.
      assertion = lib.all (m: m.subPath == null || relativeAndClean m.subPath)
        (lib.concatMap (st: st.mounts) (stateEntries app) ++ otherMountRecords app);
      message =
        "app `${app.name}` has a `subPath` that is absolute or contains `..`. A subPath is a path WITHIN "
        + "the volume and is relative by definition; the kubelet refuses both forms, and an absolute one "
        + "is almost always a `mountPath` written in the wrong field.";
    }
    {
      # A6, per CONTAINER rather than per app: three containers legitimately
      # mount one directory, and a pod-wide form would reject that.
      assertion = lib.all (v: duplicateMountPaths v.mounts == [ ]) (containerMountViews app);
      message =
        "app `${app.name}` mounts two volumes on one path inside one container: "
        + lib.concatMapStringsSep "; "
          (v: "`${v.cname}` at " + lib.concatMapStringsSep ", " (p: "`${p}`") (duplicateMountPaths v.mounts))
          (lib.filter (v: duplicateMountPaths v.mounts != [ ]) (containerMountViews app))
        + ". `volumeMounts` merges on the path, so one of them is invisible and which one depends on "
        + "emission order.";
    }
    {
      # A7.
      assertion = collidingStateKeys app == [ ];
      message =
        "app `${app.name}` has `state` keys that collide with the ordinal keys of a multi-mount volume ("
        + lib.concatMapStringsSep ", " (n: "`${n}`") (collidingStateKeys app)
        + "). The second and later mounts of a volume take the key `<volume>-NN`, so a volume already "
        + "named that would silently lose one of them. Rename one of the volumes.";
    }
    {
      # C6.
      assertion = lib.all (st: st.items == { } || st.configMap != null || st.secret != null) (stateEntries app);
      message =
        "app `${app.name}` gives `items` on state that is not backed by a `configMap` or a `secret`. "
        + "Those are the only backings that have keys to project; anywhere else it describes a "
        + "projection that does not exist, and would be dropped rather than honoured.";
    }
    {
      # C7's first half.
      assertion = lib.all (st: lib.all relativeAndClean (lib.attrValues st.items)) (stateEntries app);
      message =
        "app `${app.name}` gives an `items` path that is absolute or contains `..`. The path is where the "
        + "key lands INSIDE the volume, so it is relative by definition — an absolute one is a "
        + "`mountPath` written in the wrong field.";
    }
    {
      # A12.
      assertion = lib.all
        (st: st.ownership != "kubelet" || (durable st && identityOf app != null))
        (stateEntries app);
      message =
        "app `${app.name}` asks the kubelet to take ownership of a volume that is not durable, or does so "
        + "without an identity that resolves. Chowning a ConfigMap, a Secret or a scratch directory is "
        + "meaningless, and chowning to nothing is a no-op that reads as a setting.";
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
      # C5.
      assertion = unknownSecretConsumers app == [ ];
      message =
        "app `${app.name}` names Secret consumers it does not declare as containers: "
        + lib.concatMapStringsSep ", " (c: "`${c}`") (unknownSecretConsumers app)
        + ". A typo there silently withholds a credential, and the app fails later, further from the "
        + "cause. The app's own container is `${app.name}`.";
    }
    {
      # Per container, over that container's own `env`.
      assertion = envCollisions app == [ ];
      message =
        "app `${app.name}` defines these variables both in `env` and from a Secret, on one container: "
        + lib.concatStringsSep ", " (lib.unique (envCollisions app))
        + ". One of them would silently win.";
    }
    {
      # A11.
      assertion = lib.intersectLists (identityEnvNames app)
        (lib.attrNames app.env ++ lib.attrNames (secretKeyEnv app app.name)) == [ ];
      message =
        "app `${app.name}` spells its identity into a variable it also defines in `env` or from a Secret: "
        + lib.concatStringsSep ", " (lib.intersectLists (identityEnvNames app)
          (lib.attrNames app.env ++ lib.attrNames (secretKeyEnv app app.name)))
        + ". One would silently win, and the loser is the single numeric authority for this identity.";
    }
    {
      # A8.
      assertion = app.identity == null || app.identity == "root" || platform.identities ? ${app.identity};
      message =
        "app `${app.name}` runs as identity `${toString app.identity}`, which "
        + "`nixk3s.appPlatform.identities` does not define. An identity silently dropped is a pod running "
        + "as root with nothing in the tree saying so. Define the role, or say `identity = \"root\"` out "
        + "loud if that is what this image needs.";
    }
    {
      # A9.
      assertion = !(platform.identities ? "root");
      message =
        "`nixk3s.appPlatform.identities` defines a role called `root`. That name is reserved by this "
        + "grammar as the sentinel an app uses to say its image must start as uid 0, and shadowing it "
        + "would turn that statement into an ordinary lookup.";
    }
    {
      # A10.
      assertion = !(usesEnvIdentity app) || identityOf app != null;
      message =
        "app `${app.name}` names an `identityEnv` variable but has no identity that resolves to numbers. "
        + "The variable would carry nothing: the NAME is a fact about the image, and the NUMBER comes "
        + "from the registry entry `identity` names.";
    }
    {
      # A13 / C8, per container.
      assertion = lib.all (c: c.security.allowPrivilegeEscalation != true) (containerSecurities app);
      message =
        "app `${app.name}` sets `allowPrivilegeEscalation = true` on "
        + lib.concatMapStringsSep ", " (c: "`${c.cname}`")
          (lib.filter (c: c.security.allowPrivilegeEscalation == true) (containerSecurities app))
        + ". Every term in `security` RESTRICTS; there is no way to grant here, and that is what makes "
        + "the claim checkable rather than a slogan.";
    }
    {
      # A14.
      assertion = !app.singleWriter || app.replicas == 1;
      message =
        "app `${app.name}` declares `singleWriter` and ${toString app.replicas} replicas. `Recreate` "
        + "serializes the ROLLOUT, not the replica count you asked for — the two live copies this term "
        + "exists to prevent would run side by side anyway.";
    }
    {
      # C1.
      assertion = lib.length (lib.unique (containerNames app)) == lib.length (containerNames app);
      message =
        "app `${app.name}` declares two containers with one name (in `${app.name}` itself, `companions` "
        + "or `init`). The API server refuses such a pod, and inside an attrset the collision is "
        + "invisible: one of them simply does not exist.";
    }
    {
      # C2.
      assertion = duplicatePortNames app == [ ];
      message =
        "app `${app.name}` claims these port names on more than one container: "
        + lib.concatMapStringsSep ", " (n: "`${n}`") (duplicatePortNames app)
        + ". Kubernetes requires a container port name to be unique across the whole POD, and a "
        + "`targetPort` by name would reach whichever container the attribute sort put last — which is "
        + "not a decision anybody made.";
    }
    {
      # C3.
      assertion = undeclaredMountKeys app == [ ];
      message =
        "app `${app.name}` mounts volumes it does not declare, on a companion or init container: "
        + lib.concatMapStringsSep ", " (n: "`${n}`") (undeclaredMountKeys app)
        + ". A volume is declared once, on the app, in `state` (or as `secret-<name>` from "
        + "`secrets.<name>.mountPath`), and mounted wherever it is needed. The kubelet would refuse the "
        + "pod; this is the cheaper place to find out.";
    }
    {
      # Per container, because a probe reads a socket through its OWN
      # container's port table.
      assertion = strayProbePorts app == [ ];
      message =
        "app `${app.name}` probes a port the probing container does not declare: "
        + lib.concatMapStringsSep ", " (p: "`${p}`") (strayProbePorts app)
        + ". A probe on a neighbour's port renders a number that happens to work and a declaration that "
        + "lies.";
    }
    {
      # EXISTS FOR WHAT IT FORCES, and for what it then says. `mkService` is the
      # only reader of `servicePort`, and it now sits behind `rendersService` —
      # so on a port that declines to be published the value is discarded before
      # anything forces it, and its type is never checked. Reading it here
      # forces it whichever branch the render takes. The guard that falls out of
      # the reading is real too: a `servicePort` on an unpublished port
      # describes an entry of a Service that will never carry it.
      assertion = lib.all (e: e.p.servicePort == null || e.p.publish) (podPortEntries app);
      message =
        "app `${app.name}` names a `servicePort` on a port it does not publish ("
        + lib.concatMapStringsSep ", " (e: "`${e.where}`")
          (lib.filter (e: e.p.servicePort != null && !e.p.publish) (podPortEntries app))
        + "). `servicePort` is the number the SERVICE carries, and an unpublished port never reaches "
        + "one — the value would be dropped rather than honoured. Publish the port, or drop the number.";
    }
    {
      # "There is nothing to expose" must now mean nothing PUBLISHED.
      assertion = app.exposure == "internal" || publishedPorts app != { };
      message =
        "app `${app.name}` declares exposure `${app.exposure}` but publishes no ports. There is nothing "
        + "to expose: either no container declares one, or every one of them sets `publish = false`.";
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

  appWarnings = app: [
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
      # W2. `ownership = "kubelet"` on a node path.
      when = lib.any (st: st.ownership == "kubelet" && st.hostPath != null) (stateEntries app);
      message =
        "app `${app.name}` lets the kubelet take ownership of a directory on the NODE. `fsGroup` makes "
        + "the kubelet recursively chown that tree on EVERY pod start, and a node path is usually "
        + "curated outside the cluster — this destroys ownership somebody set deliberately.";
    }
    {
      # W3.
      when = app.security.runAsNonRoot == true && app.identity == null;
      message =
        "app `${app.name}` refuses to run as root but names no identity. The kubelet rejects the pod at "
        + "admission unless the image's own USER is numeric and non-zero, and nothing in this "
        + "declaration says it is.";
    }
    {
      # W1, per container. Not hygiene: the parent mount COVERS the child, so
      # the child's contents are invisible to the process, silently.
      when = lib.any (v: shadowedMounts v.mounts != [ ]) (containerMountViews app);
      message =
        "app `${app.name}` emits a mount before the mount that covers it: "
        + lib.concatMapStringsSep "; "
          (v: "on `${v.cname}`, " + lib.concatStringsSep ", " (shadowedMounts v.mounts))
          (lib.filter (v: shadowedMounts v.mounts != [ ]) (containerMountViews app))
        + ". Mounts are emitted in attribute-name order, so the shallower one lands last and hides the "
        + "deeper one's contents from the process. Pin the order in the private overlay, or rename the "
        + "volume keys so the ancestor sorts first.";
    }
    {
      when = app.raw != [ ];
      message =
        "app `${app.name}` passes ${toString (lib.length app.raw)} verbatim manifest(s) through the escape "
        + "hatch. Nothing types or checks those, including the boundary this grammar otherwise enforces.";
    }
  ];

  # PER CONTAINER, so a companion cannot slip an unpinned image past a warning
  # that only ever looked at the app's own.
  companionWarnings = app: lib.mapAttrsToList
    (cn: c: {
      when = !(lib.hasInfix "@sha256:" c.image);
      message =
        "app `${app.name}` companion `${cn}` uses an unpinned image (`${c.image}`). Two syncs of an "
        + "identical rendered tree can then run different code, which is exactly what this spine exists "
        + "to prevent.";
    })
    app.companions;

  initWarnings = app: map
    (c: {
      when = !(lib.hasInfix "@sha256:" c.image);
      message =
        "app `${app.name}` init container `${c.name}` uses an unpinned image (`${c.image}`). Two syncs of "
        + "an identical rendered tree can then run different code.";
    })
    app.init;

  mkWarnings = app: appWarnings app ++ companionWarnings app ++ initWarnings app;

  mkApplication = app: {
    inherit (app) name namespace createNamespace project;

    resources = {
      deployments.${app.name} = mkDeployment app;
      services.${app.name} = lib.mkIf app.rendersService (mkService app);
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
        `/scaling`, `/wake`, `/gpu`, `/node-pinned`, `/runs-as-root`). Override
        it to a domain you control if you would rather not carry this one into
        your manifests.
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

    identities = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
        options = {
          uid = lib.mkOption {
            type = lib.types.ints.unsigned;
            description = "Numeric user id this role is on this fleet.";
          };

          gid = lib.mkOption {
            type = lib.types.ints.unsigned;
            description = "Numeric group id.";
          };

          fsGroup = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = config.gid;
            defaultText = lib.literalExpression "gid";
            description = ''
              Supplementary group the kubelet applies to a volume that asked
              for it (`state.<name>.ownership = "kubelet"`). Defaults to the
              group, and is rendered ONLY when some volume asks — never by
              default.
            '';
          };
        };
      }));
      default = { };
      example = lib.literalExpression ''
        { unprivileged-app = { uid = 4242; gid = 4242; }; }
      '';
      description = ''
        THE IDENTITY REGISTRY: role name -> what that role IS, numerically, on
        this fleet. EMPTY HERE FOREVER, and holding NOTHING BUT NUMBERS.

        An app names a role and says which SHAPE it wants that role in
        (`security.*`, `identityEnv.*`); which uid a role is, is the shape of
        somebody's /etc/passwd and belongs to whoever owns it — the same split
        as `hostPathNodeSelector` and `gpuResourceName`, and the same split the
        module header already states for `namespace` and `state.<n>.hostPath`.

        The classes live on the app and the numbers live here on purpose. Live
        pod securityContexts are heterogeneous SUBSETS — one app carries three
        fields, the next carries two different ones, a third carries only a
        seccomp profile — so a registry that also owned the booleans would hand
        every app that shares a role the same bundle, and each of them would
        then force half of it back off.

        Several apps normally share one role, which is the point: this is where
        "these six apps are the same user" is written down ONCE. The role name
        `root` is reserved by the grammar and may not be defined here.
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

    multiContainerApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.attrNames (lib.filterAttrs
        (_: app: app.companions != { } || app.init != [ ])
        enabledApps);
      defaultText = lib.literalExpression "every enabled app declaring companions or init containers";
      description = ''
        Apps whose pod holds more than one container. Read-only, and COUNTABLE
        on purpose, for the same reason `rawEscapeHatchApps` is.

        A multi-container vocabulary is a large surface, and whether it earns
        that surface is a NUMBER rather than an argument. If this list stays at
        one entry, the honest reading is that the minimal-surface shape was
        right and this should be reverted before a second app depends on it. A
        consumer can assert on the list either way.
      '';
    };
  };

  options.nixk3s.apps = lib.mkOption {
    type = lib.types.attrsOf appType;
    default = { };
    description = ''
      Apps, keyed by name. Each declares WHAT IT NEEDS — an image, ports, an
      exposure class, whether it scales to zero, which existing claims or node
      paths hold its state, which existing Secrets it consumes, which identity
      it runs as — and this module renders the Argo CD Application, an optional
      Namespace, a Deployment whose pod may hold several containers, and (when
      any container publishes a port) a Service.

      The vocabulary is need-shaped: a declaration written against it names
      objects, roles and classes, and takes any fleet fact as a parameter its
      consumer supplies. See the header of this module for the boundary in full,
      and for the two ways out of the grammar when an app needs something it has
      no term for.
    '';
    example = lib.literalExpression ''
      {
        example-app = {
          namespace = "example-apps";
          image = "registry.example.com/example/app:1.2.3@sha256:...";
          ports.http.number = 8080;
          exposure = "public";
          identity = "unprivileged-app";
          state.data = { claim = "example-app-data"; mountPath = "/data"; };
          secrets.credentials.env.APP_PASSWORD = "password";
          probes.readiness = { port = "http"; path = "/healthz"; };
        };
      }
    '';
  };

  config.applications = lib.mapAttrs (_: mkApplication) enabledApps;
}
