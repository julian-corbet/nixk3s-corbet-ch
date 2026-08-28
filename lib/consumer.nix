#
# mkConsumerModule — the CONSUMER side of the app grammar, published once.
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────────────
#
# This repository publishes `nixk3s.apps`: a workload declares WHAT IT NEEDS and the grammar
# renders the Application, the Namespace, the Deployment and the Service. What it did NOT publish
# was any way to CONSUME that grammar from a catalogue — so every repository that owns a catalogue
# wrote its own translator, and fourteen of them now exist.
#
# They are not fourteen designs. They are one design copied fourteen times: `addressingOf` is
# byte-identical in nine of them, `imageOf` in seven, and `probesOf`/`stateOf`/`portsOf`/
# `secretsOf` appear in twelve or thirteen apiece. Copies age separately, and they did. A term
# added to the grammar reached eight of thirteen translators and stopped, because the pass that
# added it only looked at the repositories a consumer happened to compose; the other five kept a
# different name for the same option and nothing noticed for two weeks.
#
# So the divergence was never taste. It was a missed migration wave that nothing could have
# caught, because there was no single place where "the consumer surface" existed to be changed.
# This file is that place. A repository now says which catalogue it owns and what is unusual about
# it, and gets the rest — the whole declaration vocabulary, the knowledge/value split, the
# assertions and the warnings — from here.
#
# ── THE SPLIT THIS ENFORCES ────────────────────────────────────────────────────────────────────
#
# A catalogue holds what is true of the software ANYWHERE. A declaration holds what is true of ONE
# cluster. Four fields are split down the middle rather than assigned to a side, and each is
# refused in both directions:
#
#   state       catalogue: WHERE inside the container   declaration: WHAT BACKS IT
#   probes      catalogue: WHICH probes, WHAT they ask  declaration: THIS cluster's budget
#   credentials catalogue: WHICH VARIABLES carry them   declaration: WHICH SECRET delivers them
#   hardening   catalogue: what the software TOLERATES  declaration: whether to STAMP it
#
# ── WHAT IS DELIBERATELY NOT HERE ──────────────────────────────────────────────────────────────
#
# No option forwards a nested attrset into the grammar untouched. `resources` names four scalars
# rather than taking the grammar's `attrsOf str`, because a free-form resource map is how a device
# request — which is a catalogue fact and belongs to the software — gets smuggled in through a
# deployment. Hardening CLASSES are not declarable at all: they are catalogued, and a deployment
# gets one boolean saying whether they are stamped. Anything genuinely beyond this vocabulary is a
# typed merge on the rendered object in the consumer's own tree, where somebody types it on
# purpose and a reader can count it.
#
# ── THE TAIL ───────────────────────────────────────────────────────────────────────────────────
#
# Nine catalogue fields are read by most translators; roughly sixty are read by exactly one — WOPI
# hosts, a retention argument, a write probe, a GPU hook. Those are not boilerplate and pretending
# they were universal would be a worse lie than the copies. A repository passes `extend` to add
# what only it knows, and `extraOptions` for the declaration terms that go with it.
#
{ lib }:

let
  # ── Entry normalisation ──────────────────────────────────────────────────────────────────────
  #
  # The catalogues agree on WHICH facts they carry and disagree on the SHAPE of two of them, for
  # no reason beyond the order they were written in. Both spellings are accepted and normalised
  # here rather than rewritten in thirteen catalogues, because a catalogue's job is to be true and
  # `ports.http = 8080` is exactly as true as `ports.http = { number = 8080; }`.
  normalisePort = p: if lib.isInt p then { number = p; } else p;

  # ONE VOLUME, SEVERAL PLACES. Real software mounts one directory at four to six paths -- a
  # config subdirectory, a data subdirectory, a log subdirectory, each a `subPath` of the same
  # volume. A catalogue may therefore write one mount path or a list of them, and the shorthand is
  # the list of length one.
  mountsOfEntry = e:
    if lib.isString e then [ { mountPath = e; } ]
    else if (e.mounts or [ ]) != [ ] then e.mounts
    else [ { mountPath = e.mountPath; } ];

  # ORDER IS SEMANTIC and is preserved: the first mount takes the volume's own name and the rest
  # take ordinals, so the attribute sort reproduces exactly what the catalogue wrote. A factory
  # that reordered, deduped or re-keyed this list would move mount zero.
  pathsOfEntry = e: map (m: m.mountPath) (mountsOfEntry e);

  mountPathOf = e: (lib.head (mountsOfEntry e)).mountPath;
  entryReadOnly = e: if lib.isString e then null else (e.readOnly or null);

  # Probes arrive two ways: a `probes` attrset keyed by kind, or one field per kind. Same fact.
  probeShapesOf = entry:
    if entry ? probes then entry.probes
    else lib.filterAttrs (_: v: v != null) {
      readiness = entry.readiness or null;
      liveness = entry.liveness or null;
      startup = entry.startup or null;
    };

  dropNulls = lib.filterAttrs (_: v: v != null);
in

{ namespace
, optionPath ? [ namespace ]
, catalogue ? null
, roots ? null
, root ? "applications"
, selector ? "app"
, platformOption ? "clusterPlatform"
, extraPlatformOptions ? { }
, extraNamespaceOptions ? { }
, extraOptions ? { }
, extend ? (_entry: _w: app: app)
, extraAssertions ? (_workloads: [ ])
, extraWarnings ? (_workloads: [ ])
, extraConfig ? (_workloads: { })
}:

{ config, lib, options, ... }:

let
  checkedOptionPath =
    if !builtins.isList optionPath
      || optionPath == [ ]
      || !(lib.all (part: lib.isString part && part != "") optionPath)
    then throw "mkConsumerModule: optionPath must be a non-empty list of non-empty strings"
    else optionPath;
  showPathPart = part:
    if builtins.match "[A-Za-z_][A-Za-z0-9_-]*" part != null
    then part
    else builtins.toJSON part;
  optionPathText = lib.concatMapStringsSep "." showPathPart checkedOptionPath;
  cfg = lib.getAttrFromPath checkedOptionPath config;
  platform = cfg.${platformOption};
  addressingIsDefined = lib.hasAttrByPath [ "nixk3s" "addressing" "reservations" ] options;

  # Roots may remove a term structurally. The renderer still works against one total internal
  # record so an absent optional term means its closed/null value rather than an attribute error
  # that arrives before a root's own guard. These are renderer fallbacks, NOT option defaults: a
  # removed option remains unwritable, and an enabled option keeps the documented default below.
  workloadDefaults = {
    enable = true;
    version = null;
    image = null;
    manifests = [ ];
    companionImages = { };
    companionResources = { };
    initImages = { };
    objectName = null;
    replicas = null;
    namespace = null;
    createNamespace = false;
    project = null;
    slot = null;
    exposure = "internal";
    scaling = "always";
    wake = null;
    adopt = false;
    harden = true;
    state = { };
    probes = { };
    resources = {
      cpuRequest = null;
      memoryRequest = null;
      cpuLimit = null;
      memoryLimit = null;
    };
    credentials = {
      secret = null;
      keys = { };
      secrets = { };
    };
    requires = { };
    publicUrl = null;
    identity = null;
    env = { };
    args = [ ];
  };

  # ONE ROOT was enough for the first three adopters and is still the small API. `roots` is the
  # general form for catalogues whose user-facing concepts genuinely are several tables (database
  # operators/instances/tools, CI forges/servers/runners/jobs). They are normalised to the same
  # internal shape, so the old call is not a second implementation and cannot age separately.
  #
  # A root may either select from a catalogue:
  #
  #   services = { catalogue = catalogues.services; selector = "service"; ...; };
  #
  # or carry one fixed synthetic entry (a schedule is not software and has no catalogue key):
  #
  #   jobs = { entry = jobEntry; ...; };
  #
  # `kind` dispatches each SELECTED ENTRY to `app`, `manifest`, or `reference`. It is deliberately
  # a function of the entry rather than an option in the declaration: whether Postgres is an
  # operator-owned custom resource, or whether a forge is somebody else's, is knowledge about the
  # thing and cannot vary by cluster.
  rawRoots =
    if roots != null && catalogue != null then
      throw "mkConsumerModule: pass either `catalogue` (one root) or `roots` (several), never both"
    else if roots != null then roots
    else if catalogue != null then {
      ${root} = {
        inherit catalogue selector extraOptions;
        extend = { entry, w, app, ... }: extend entry w app;
      };
    }
    else
      throw "mkConsumerModule: one of `catalogue` or `roots` is required";

  normaliseRoot = rootName: r:
    let
      hasCatalogue = r ? catalogue;
      hasEntry = r ? entry;
    in
    if hasCatalogue == hasEntry then
      throw "mkConsumerModule: root `${rootName}` must define exactly one of `catalogue` or `entry`"
    else {
      inherit rootName;
      catalogue = r.catalogue or null;
      entry = r.entry or null;
      selector = r.selector or "app";
      selectorDefault = r.selectorDefault or null;
      enabledOptions = r.enabledOptions or null;
      disabledOptions = r.disabledOptions or [ ];
      extraOptions = r.extraOptions or { };
      enableByDefault = r.enableByDefault or (_: true);
      defaults = r.defaults or (_: { });
      kind = r.kind or (_: "app");
      namespaceOf = r.namespaceOf or ({ w, ... }: w.namespace);
      projectOf = r.projectOf or ({ w, ... }: w.project);
      createNamespaceOf = r.createNamespaceOf or ({ w, ... }: w.createNamespace or false);
      manifestsOf = r.manifestsOf or ({ w, ... }: w.manifests or [ ]);
      nameOf = r.nameOf or ({ name, w, ... }:
        if (w.objectName or null) != null then w.objectName else name);
      volumeNameOf = r.volumeNameOf or ({ w, ... }: key:
        let resolved = w.state.${key}.volumeName or null; in
        if resolved != null then resolved else key);
      requiredStateKeys = r.requiredStateKeys or ({ entry, ... }: lib.attrNames (entry.state or { }));
      allowedStateKeys = r.allowedStateKeys or ({ entry, ... }: lib.attrNames (entry.state or { }));
      extend = r.extend or ({ app, ... }: app);
      extendManifest = r.extendManifest or ({ application, ... }: application);
      assertions = r.assertions or (_: [ ]);
      warnings = r.warnings or (_: [ ]);
      description = r.description or null;
    };

  rootSpecs = lib.mapAttrs normaliseRoot rawRoots;

  # `extraOptions` is an overlay with two meanings. Over an ENABLED common term it refines the
  # module contract while the generic renderer stays responsible (a required string `version`,
  # for example). Over a DISABLED common term it redeclares an incompatible domain shape and the
  # root takes responsibility for rendering and guards (role credentials, legacy state/sizing).
  # Keep the marker from common-option selection rather than looking at the final option set,
  # where either kind of overlay is intentionally present.
  usesCommonOption = spec: option:
    if spec.enabledOptions != null
    then lib.elem option spec.enabledOptions
    else !(lib.elem option spec.disabledOptions);

  anyRootUsesCommonOption = option:
    lib.any (spec: usesCommonOption spec option) (lib.attrValues rootSpecs);

  selectionOf = spec: w:
    if spec.entry != null then spec.rootName else w.${spec.selector};

  entryOf = spec: w:
    if spec.entry != null then spec.entry else spec.catalogue.${w.${spec.selector}};

  contextOf = spec: name: declaration:
    let
      entry = entryOf spec declaration;
      selected = selectionOf spec declaration;
      w = workloadDefaults // declaration;
      base = {
        inherit name w entry selected platform;
        inherit declaration;
        consumer = cfg;
        moduleConfig = config;
        root = spec.rootName;
        inherit spec;
      };
      kind = spec.kind base;
    in base // { inherit kind; };

  declaredByRoot = lib.mapAttrs
    (rootName: spec: lib.filterAttrs (_: w: w.enable) cfg.${rootName})
    rootSpecs;

  allWorkloads = lib.concatLists (lib.mapAttrsToList
    (rootName: spec: lib.mapAttrsToList (contextOf spec) declaredByRoot.${rootName})
    rootSpecs);

  # A callback is outside the module option type system. Guard its type before equality: Nix
  # cannot compare a function with a string, and a raw equality error would arrive before the
  # dispatch assertion that is meant to explain an invalid callback result.
  isKind = expected: x: lib.isString x.kind && x.kind == expected;

  workloads = lib.filter (isKind "app") allWorkloads;
  manifestWorkloads = lib.filter (isKind "manifest") allWorkloads;
  referenceWorkloads = lib.filter (isKind "reference") allWorkloads;
  commonStateWorkloads = lib.filter (x: usesCommonOption x.spec "state") workloads;
  nonGrammarSlotWorkloads = lib.filter
    (x: (x.w.slot or null) != null)
    (manifestWorkloads ++ referenceWorkloads);

  addressingAvailabilityAssertions = lib.optional
    (!addressingIsDefined && platform.origin != null && nonGrammarSlotWorkloads != [ ])
    {
      assertion = false;
      message =
        "${namespace}: manifest/reference workloads claim slots while `${optionPathText}.${platformOption}.origin` "
        + "is set, but the nixk3s addressing module is not composed. Their occupancy cannot be "
        + "published as reservations, so live slots would appear free.";
    };

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks
  # like. The catalogue never carries either: a version is a deployment's choice and a digest is
  # one deployment's proof of what it is running.
  # A CATALOGUE ENTRY MAY HAVE NO IMAGE AT ALL -- software nobody publishes a container for, where
  # upstream ships a build recipe and you bring your own. That is a fact about the software, so it
  # is the catalogue's to state, and a declaration must then carry a whole reference. Guarded
  # below rather than here: reaching for `"${null}:${version}"` replaces a sentence somebody can
  # act on with a coercion error.
  imageOf = entry: w:
    if w.image != null then w.image
    else if (entry.image or null) != null && w.version != null
    then "${entry.image}:${w.version}"
    # The assertions below own both missing halves. Keep construction total so a consumer that
    # forces the generated app while collecting another assertion still reaches those sentences
    # instead of dying first while interpolating `null`.
    else "";

  portsOf = entry: lib.mapAttrs (_: normalisePort) entry.ports;

  # The split in one function: WHERE inside the container comes from the catalogue, WHAT BACKS IT
  # comes from the declaration, and neither side can supply the other's half.
  # The rendered volume's NAME defaults to the catalogue key unless the declaration says the live
  # object calls it something else. A root may resolve it instead when an established public state
  # key is semantic rather than a Kubernetes name; every rendered and guarded use goes through the
  # same resolver below.
  volumeNameOf = x: key: x.spec.volumeNameOf x key;

  # KEYS BOTH SIDES KNOW ABOUT. The guard that catches a directory only one side has is a state
  # assertion; every use of the catalogue that indexes it BY A DECLARATION'S KEY must walk the
  # intersection instead, or it throws a missing-attribute error while the assertion written to
  # explain the mistake is still being collected -- and the author gets a crash where a sentence
  # was waiting for them.
  sharedStateKeys = entry: w:
    lib.filter (k: (entry.state or { }) ? ${k}) (lib.attrNames w.state);

  # WHICH BACKINGS THIS SOFTWARE ACCEPTS, when the catalogue has an opinion. Five are offered; a
  # database accepts two. `emptyDir` under a database is a directory that is discarded on exactly
  # the restart the state exists to survive, and offering it at all is offering a silent disaster
  # -- so a catalogue may name the subset it tolerates and the rest stop being expressible.
  #
  # The default is every backing, because a catalogue that has not thought about it should not be
  # narrowing anything by accident.
  allBackings = [ "claim" "hostPath" "configMap" "secret" "emptyDir" ];

  backingsAllowed = entry: key:
    let e = entry.state.${key} or null; in
    if lib.isString e || e == null then allBackings else (e.backings or allBackings);

  backingChosen = backing:
    lib.head (lib.filter (b: b != null) [
      (if (backing.claim or null) != null then "claim" else null)
      (if (backing.hostPath or null) != null then "hostPath" else null)
      (if (backing.configMap or null) != null then "configMap" else null)
      (if (backing.secret or null) != null then "secret" else null)
      (if backing.emptyDir or false then "emptyDir" else null)
    ] ++ [ null ]);

  stateOf = x@{ entry, w, ... }:
    lib.mapAttrs'
      (key: backing:
        let ro = entryReadOnly entry.state.${key}; in
        let
          ms = mountsOfEntry entry.state.${key};
          ro' = if ro != null then ro else backing.readOnly or false;
        in
        lib.nameValuePair (volumeNameOf x key) (
          {
            claim = backing.claim or null;
            hostPath = backing.hostPath or null;
            hostPathType = backing.hostPathType or "Directory";
            configMap = backing.configMap or null;
            secret = backing.secret or null;
            emptyDir = backing.emptyDir or false;
            ownership = backing.ownership or "site-curated";
          }
          # `mountPath` and `mounts` are alternatives in the grammar, not a pair.
          // (if lib.length ms == 1
          then { mountPath = (lib.head ms).mountPath; readOnly = ro'; }
          else {
            mounts = map
              (m: { inherit (m) mountPath; subPath = m.subPath or null; readOnly = m.readOnly or ro'; })
              ms;
          })
        ))
      (lib.getAttrs (sharedStateKeys entry w) w.state);

  # The same split, for probes. The catalogue decides WHICH probes exist and WHAT THEY ASK FOR —
  # the endpoint, the port, and how long one answer may take, which is a property of the software
  # answering. A declaration overrides the BUDGET: how often to ask and how many failures to
  # tolerate, which is how much slowness one cluster is willing to absorb. An unstated budget
  # field is the catalogue's, so a declaration states only what it is changing.
  probesOf = entry: w:
    lib.mapAttrs
      (kind: shape:
        let
          budget = w.probes.${kind} or null;
          take = field:
            if budget != null && budget.${field} != null then budget.${field}
            else shape.${field} or null;
        in
        dropNulls {
          port = entry.primaryPort;
          path = shape.path or null;
          periodSeconds = take "periodSeconds";
          failureThreshold = take "failureThreshold";
          timeoutSeconds = take "timeoutSeconds";
          initialDelaySeconds =
            if budget != null && budget.initialDelaySeconds != null then budget.initialDelaySeconds
            else shape.initialDelaySeconds or null;
        })
      (probeShapesOf entry);

  # HARDENING: the catalogue holds the CLASSES, the declaration holds one boolean saying whether
  # this deployment stamps them. Both halves are real. "This app needs no Linux capability and
  # never has to regain privilege" is true of the software wherever it runs; whether a given pod
  # CARRIES those fields is not, because a live object that predates them takes a rollout to
  # acquire them and some clusters enforce the same thing at admission instead.
  #
  # Every term restricts, and the mapping is lossy in that direction on purpose: there is no
  # spelling here for adding a capability or allowing escalation, so a catalogue entry cannot
  # widen a pod no matter what it says.
  securityOf = entry: w:
    let h = entry.hardening or null; in
    lib.optionalAttrs (w.harden && h != null) (
      lib.optionalAttrs ((h.capabilities or null) == "none") { capabilitiesDrop = [ "ALL" ]; }
      // lib.optionalAttrs ((h.privilegeEscalation or null) == "never") { allowPrivilegeEscalation = false; }
      // lib.optionalAttrs ((h.seccomp or null) != null) { seccomp = h.seccomp; }
      # ONLY THE RESTRICTION RENDERS. `read-only` is an established fact about the software and
      # becomes a field; `writable` and `unestablished` render nothing at all, for two different
      # reasons that land in the same place. `unestablished` means nobody has run this with a
      # read-only root and confirmed it works, and a class asserted without that is a guess wearing
      # a restriction's clothes. `writable` is established -- but `false` is already the platform's
      # default, so writing it out says nothing about the software and everything about what one
      # live container happens to carry, which is a cluster's history and belongs in a typed merge
      # where somebody types it on purpose.
      // lib.optionalAttrs ((h.rootFilesystem or null) == "read-only") {
        readOnlyRootFilesystem = true;
      }
      // lib.optionalAttrs ((h.runAsNonRoot or null) != null) { inherit (h) runAsNonRoot; }
    );

  # Four named scalars in, two maps out, nulls dropped. A field nobody set renders no key, which
  # is what lets a declaration carry exactly the subset its live object already has.
  resourcesOf = w: resourcesFrom w.resources;

  # WHICH VARIABLES carry credentials is the catalogue's; WHICH SECRET delivers them, and under
  # which keys, is the declaration's. Named keys rather than a wholesale `envFrom`: every variable
  # this software reads is already known by name, so a key added to the Secret later has no
  # business appearing in the process environment unannounced.
  #
  # Nothing here can carry a secret's CONTENT, which is what makes a declaration written against
  # this module safe to publish.
  # ONE Secret for every credential variable is the common case and the default. It is not the only
  # one: a workload can read one credential from a Secret somebody else owns and the rest from its
  # own, and a repository that could not say so would have to fork this option to say it. So a
  # per-variable override sits beside the default, the variables are GROUPED by whichever Secret
  # ends up delivering them, and the single-Secret case falls out as the group of size one.
  secretFor = w: v: w.credentials.secrets.${v} or w.credentials.secret;
  keyFor = w: v: w.credentials.keys.${v} or v;

  secretsOf = entry: w:
    let
      vars = entry.credentials or [ ];
      covered = lib.filter (v: secretFor w v != null) vars;
    in
    lib.mapAttrs
      (secretName: vs: {
        secret = secretName;
        env = lib.listToAttrs (map (v: lib.nameValuePair v (keyFor w v)) vs);
      })
      (lib.groupBy (secretFor w) covered);

  # ── Other containers in the pod ──────────────────────────────────────────────────────────────
  #
  # A workload is not always one process. Two shapes exist and they are not interchangeable:
  #
  #   init        containers that run TO COMPLETION, IN ORDER, before the app's own starts.
  #               A list, because the order is the semantics -- an attrset would silently
  #               alphabetise any sequence that is not already alphabetical.
  #   companions  containers that run ALONGSIDE for the pod's life. An attrset, because their
  #               order is not a fact about anything.
  #
  # Both are CATALOGUE knowledge: which processes this software is, what each one runs, which of
  # the app's own directories each one sees. What a declaration owns is what it owns everywhere
  # else -- which build runs, and what it costs on this hardware.

  # THREE WAYS A CONTAINER GETS AN IMAGE, and the middle one is the common case people forget: a
  # process that ships inside the application's own installation has no image of its own.
  #   catalogue says null           -> the app's own image, and a declaration may not override it
  #   catalogue names a repository  -> the declaration MUST supply a whole reference
  # The fallback is deliberately the bare untagged repository: a total value, so the assertion
  # below has something to speak about, and unusable enough that nothing quietly runs on it.
  containerImageOf = entry: w: given: c:
    if (c.image or null) == null then imageOf entry w
    else if given != null then given
    else c.image;

  # Mounts are keyed by the CATALOGUE's name for a directory and must land on the volume this
  # DEPLOYMENT calls it. That coupling is easy to miss and fails loudly but late: a companion
  # mounting a volume the app no longer declares is refused by the grammar, not here.
  remapMounts = x@{ spec, w, ... }: ms:
    if usesCommonOption spec "state" then
      lib.mapAttrs' (k: v: lib.nameValuePair (if w.state ? ${k} then volumeNameOf x k else k) v) ms
    else
      ms;

  containerSecurityOf = entry: w: c:
    let h = c.hardening or null; in
    lib.optionalAttrs (w.harden && h != null) (
      lib.optionalAttrs ((h.capabilities or null) == "none") { capabilitiesDrop = [ "ALL" ]; }
      // lib.optionalAttrs ((h.privilegeEscalation or null) == "never") { allowPrivilegeEscalation = false; }
      // lib.optionalAttrs ((h.rootFilesystem or null) == "read-only") { readOnlyRootFilesystem = true; }
    );

  # A probe reads a socket through its OWN container's port table, which is the whole reason a
  # probe is not a property of the app.
  containerProbesOf = c:
    lib.optionalAttrs ((c.readiness or null) != null) {
      readiness = dropNulls ({ port = c.primaryPort; } // c.readiness);
    }
    // lib.optionalAttrs ((c.liveness or null) != null) {
      liveness = dropNulls ({ port = c.primaryPort; } // c.liveness);
    };

  companionsOf = x@{ spec, entry, w, ... }:
    lib.mapAttrs
      (cname: c:
        {
          image = containerImageOf entry w (w.companionImages.${cname} or null) c;
          command = c.command or [ ];
          args = c.args or [ ];
          env = c.env or { };
          ports = lib.mapAttrs (_: normalisePort) (c.ports or { });
          mounts = remapMounts x (c.mounts or { });
          security = containerSecurityOf entry w c;
          probes = containerProbesOf c;
          # A companion nobody sized asks for nothing, which renders no `resources` block at all
          # rather than a zero -- a different and much worse claim.
          resources =
            if usesCommonOption spec "companionResources"
            then resourcesFrom (w.companionResources.${cname} or null)
            else resourcesFrom null;
        })
      (entry.companions or { });

  initOf = x@{ entry, w, ... }:
    map
      (c: {
        inherit (c) name;
        image = containerImageOf entry w (w.initImages.${c.name} or null) c;
        command = c.command or [ ];
        args = c.args or [ ];
        env = c.env or { };
        mounts = remapMounts x (c.mounts or { });
        security = containerSecurityOf entry w c;
        # NO PORTS AND NO PROBES: the API server rejects a readiness probe on a non-restartable
        # init container, and a port on a process that has already exited is a fact about nothing.
      })
      (entry.init or [ ]);

  resourcesFrom = r:
    if r == null then { requests = { }; limits = { }; }
    else {
      requests = dropNulls { cpu = r.cpuRequest; memory = r.memoryRequest; };
      limits = dropNulls { cpu = r.cpuLimit; memory = r.memoryLimit; };
    };

  # WHERE ANOTHER SERVICE IS. The catalogue names the VARIABLE this software reads an endpoint
  # from; the declaration says what the endpoint is. Neither half is the other's: which variable a
  # program looks in is a property of the program, and what answers on the other end is a property
  # of one cluster on one day.
  requiresEnvOf = entry: w:
    lib.mapAttrs' (key: r: lib.nameValuePair (entry.requires.${key}).env r.endpoint) w.requires;

  # ITS OWN PUBLIC URL, for the software that has to generate links to itself. Same split: the
  # catalogue names the variable, the declaration supplies the URL, and a catalogue that names no
  # such variable makes the declaration's `publicUrl` unreachable rather than silently ignored.
  selfEnvOf = entry: w:
    lib.optionalAttrs ((entry.selfUrlEnv or null) != null && w.publicUrl != null) {
      ${entry.selfUrlEnv} = w.publicUrl;
    };

  # WHO IT RUNS AS. A ROLE, never a number: the grammar resolves a role against the consumer's own
  # identity registry, so a uid typed here would be a second authority on it. The catalogue's part
  # is narrow and factual -- whether the image must START as root before dropping, and which
  # variable (if any) the software reads its own uid from.
  identityOf = entry: w:
    if (entry.identityEnv or null) != null && w.identity != null
    then { identity = w.identity; identityEnv = entry.identityEnv; }
    else if (entry.rootStart or false) then { identity = "root"; }
    else lib.optionalAttrs (w.identity != null) { identity = w.identity; };

  # ── The address test ─────────────────────────────────────────────────────────────────────────
  #
  # An endpoint names a SERVICE. An address is a fact about one network on one day, and a workload
  # handed one has been handed something that will be wrong later and wrong SILENTLY -- the
  # connection simply stops being answered. Refusing the literal is also what keeps a declaration
  # written against this module publishable.
  authorityOf = url:
    lib.head (lib.splitString "/" (lib.last (lib.splitString "://" url)));
  hostOf = url: lib.head (lib.splitString ":" (lib.last (lib.splitString "@" (authorityOf url))));

  digits = lib.stringToCharacters "0123456789";
  isAddress = url:
    let host = hostOf url; in
    # A bracketed authority is IPv6 and nothing else; the rest is the dotted-quad test, which needs
    # the dot as well as the digits -- a bare number is a name somebody is allowed to have.
    lib.hasPrefix "[" (authorityOf url)
    || (host != ""
        && lib.hasInfix "." host
        && lib.all (c: c == "." || lib.elem c digits) (lib.stringToCharacters host));

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op.
  addressingOf = w:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      slot = w.slot or null;
    };

  renderNameOf = x: x.spec.nameOf x;

  mkApp = x:
    let
      inherit (x) entry w spec;
      namespace' = spec.namespaceOf x;
      project' = spec.projectOf x;
      createNamespace' = spec.createNamespaceOf x;
      base = {
        namespace = namespace';
        project = project';
        createNamespace = createNamespace';
        name = renderNameOf x;
        exposure = w.exposure or "internal";
        scaling = w.scaling or "always";
        adopt = w.adopt or false;
        image = imageOf entry w;
        ports = portsOf entry;
        state = if usesCommonOption spec "state" then stateOf x else { };
        secrets = if usesCommonOption spec "credentials" then secretsOf entry w else { };
        # ORDER IS THE POINT. The catalogue's own environment first, then the endpoints of the
        # services this one needs, then its own public URL, then whatever the declaration adds --
        # so a consumer can override any of it and nothing can override the consumer.
        env = (entry.env or { }) // requiresEnvOf entry w // selfEnvOf entry w // w.env;
        args = (entry.args or [ ]) ++ w.args;
        probes = probesOf entry w;
        security = securityOf entry w;
        resources = if usesCommonOption spec "resources" then resourcesOf w else resourcesFrom null;

        # THREE TERMS THE GRAMMAR HAS AND THIS FACTORY NEVER FORWARDED. Each is a fact about the
        # software, stated in a catalogue, that reached the grammar in some hand-written
        # translators and not others -- the exact failure this file exists to end, reproduced
        # inside it.
        #
        # `singleWriter` is the sharp one. A catalogue saying two copies of this must never run at
        # once, on software whose state is not a directory the grammar can see, renders a ROLLING
        # UPDATE without it: two processes briefly sharing a warm store, which is the hazard the
        # field was added to name. One repository in this family had exactly that, declared and
        # dropped, and was safe only where a node path happened to force Recreate anyway.
        command = entry.command or [ ];
        gpu = entry.gpu or false;
        singleWriter = entry.singleWriter or false;
      }
      // lib.optionalAttrs ((entry.init or [ ]) != [ ]) { init = initOf x; }
      // lib.optionalAttrs ((entry.companions or { }) != { }) { companions = companionsOf x; }
      // lib.optionalAttrs ((w.replicas or null) != null) { inherit (w) replicas; }
      // lib.optionalAttrs ((w.wake or null) != null) { inherit (w) wake; }
      // identityOf entry w
      // addressingOf w;
      extended = spec.extend (x // { app = base; });
    in
    # An extension may add domain fields but cannot change the identity/tenancy inputs that the
    # central collision and namespace-anchor guards reasoned about.
    extended // {
      name = renderNameOf x;
      namespace = namespace';
      project = project';
      createNamespace = createNamespace';
    };

  # A manifest delivery is one Application and a list of whole objects. Custom resources and
  # rendered Helm charts are intentionally the SAME kind here: nixidy does not interpret either
  # schema, and this factory must not pretend it can validate an operator's API version. The
  # Application still gets the two adoption-safe switches every surveyed translator repeated.
  mkManifestApplication = x:
    let
      base = {
        namespace = x.spec.namespaceOf x;
        project = x.spec.projectOf x;
        createNamespace = false;
        yamls = x.spec.manifestsOf x;
        syncPolicy.syncOptions.serverSideApply = true;
        compareOptions.serverSideDiff = true;
      };
      extended = x.spec.extendManifest (x // { application = base; });
    in
    # The direct Application's module key is already `nameOf`; it has no second name field. Its
    # tenancy and delivery-safety fields remain factory-owned after a domain extension.
    lib.recursiveUpdate extended {
      namespace = x.spec.namespaceOf x;
      project = x.spec.projectOf x;
      createNamespace = false;
      yamls = x.spec.manifestsOf x;
      syncPolicy.syncOptions.serverSideApply = true;
      compareOptions.serverSideDiff = true;
    };

  # ── Assertions ───────────────────────────────────────────────────────────────────────────────
  #
  # Every one of these refuses a declaration that would otherwise render something the author did
  # not mean. They are phrased as questions about the SPLIT: a half supplied without its other
  # half, or a half supplied for something that has none.

  stateAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry selected spec;
        catalogued = lib.attrNames (entry.state or { });
        required = spec.requiredStateKeys x;
        allowed = spec.allowedStateKeys x;
        declared = lib.attrNames w.state;
        requiredOutsideAllowed = lib.filter (key: !(lib.elem key allowed)) required;
        allowedOutsideCatalogue = lib.filter (key: !(lib.elem key catalogued)) allowed;
        missing = lib.filter (key: !(lib.elem key declared)) required;
        unknown = lib.filter (key: !(lib.elem key catalogued)) declared;
        forbidden = lib.filter
          (key: lib.elem key catalogued && !(lib.elem key allowed))
          declared;
        showKeys = keys: lib.concatMapStringsSep ", " (key: "`${key}`") keys;
      in
      [
        {
          assertion = requiredOutsideAllowed == [ ];
          message =
            "${namespace}: root `${x.root}` marks ${showKeys requiredOutsideAllowed} as required "
            + "state for `${selected}` but not allowed state. `requiredStateKeys` must be a subset "
            + "of `allowedStateKeys`; otherwise no declaration can satisfy the root contract.";
        }
        {
          assertion = allowedOutsideCatalogue == [ ];
          message =
            "${namespace}: root `${x.root}` allows ${showKeys allowedOutsideCatalogue} as state for "
            + "`${selected}`, but the catalogue does not name those directories. `allowedStateKeys` "
            + "must be a subset of the catalogue's state keys.";
        }
        {
          assertion = missing == [ ];
          message =
            "${namespace}: workload `${name}` must back every directory it writes that this root "
            + "marks required, and is missing ${showKeys missing}. Required: "
            + (if required == [ ] then "none" else showKeys required) + ".";
        }
        {
          assertion = unknown == [ ];
          message =
            "${namespace}: workload `${name}` must back every directory it writes using catalogue "
            + "keys, and declares unknown state ${showKeys unknown}. Catalogued: "
            + (if catalogued == [ ] then "none" else showKeys catalogued) + ".";
        }
        {
          assertion = forbidden == [ ];
          message =
            "${namespace}: workload `${name}` declares ${showKeys forbidden}, which is catalogued "
            + "state for `${selected}` but forbidden for this declaration by `allowedStateKeys`. "
            + "Allowed here: " + (if allowed == [ ] then "none" else showKeys allowed) + ".";
        }
        {
          assertion = lib.all
            (backing:
              lib.length (lib.filter (b: b) [
                ((backing.claim or null) != null)
                ((backing.hostPath or null) != null)
                ((backing.configMap or null) != null)
                ((backing.secret or null) != null)
                (backing.emptyDir or false)
              ]) == 1)
            (lib.attrValues w.state);
          message =
            "${namespace}: workload `${name}` must back each directory with EXACTLY ONE of a claim, "
            + "a node path, a ConfigMap, a Secret or a scratch directory -- never several and never "
            + "none. A directory with no backing is a pod's own filesystem, which is discarded on "
            + "exactly the restart that state exists to survive.";
        }
        {
          # A rename is per directory; two of them landing on one name is one volume where the
          # declaration says two, and the second silently wins.
          assertion =
            let names = map (k: volumeNameOf x k) (lib.attrNames w.state); in
            lib.length (lib.unique names) == lib.length names;
          message =
            "${namespace}: workload `${name}` renames two directories onto one volume name. One of "
            + "them would simply not be mounted, and which one is an accident of attribute order.";
        }
        {
          # THE CATALOGUE'S OWN SHORTLIST. Five backings exist; a catalogue that names fewer is
          # saying this software cannot survive the others, and the refused one is refused rather
          # than merely discouraged.
          assertion = lib.all
            (key:
              let chosen = backingChosen w.state.${key}; in
              chosen == null || lib.elem chosen (backingsAllowed entry key))
            (sharedStateKeys entry w);
          message =
            "${namespace}: workload `${name}` backs a directory with something `${selected}` "
            + "does not accept for it. The catalogue names what this software's data can live on, "
            + "and the rest are not a worse choice, they are a silent one -- a scratch directory "
            + "under a database is discarded on exactly the restart that state exists to survive.";
        }
        {
          # The catalogue's half of an ownership decision: a directory it says GROWS must never be
          # chowned recursively on every pod start, because that cost scales with the tree and the
          # tree is the thing that keeps getting bigger.
          assertion = lib.all
            (key:
              !((entry.state.${key}.grows or false)
                && (w.state.${key}.ownership or "site-curated") == "kubelet"))
            (sharedStateKeys entry w);
          message =
            "${namespace}: workload `${name}` asks the kubelet to own a directory the catalogue says "
            + "GROWS. That means chowning it recursively on every single pod start, over a tree "
            + "whose whole purpose is to keep getting bigger -- and on a path somebody curates "
            + "outside the cluster it destroys ownership that was set there deliberately.";
        }
      ])
    commonStateWorkloads;

  # A budget is an override of something, so there has to be something. Budgeting a probe the
  # software does not warrant is the same class of mistake as backing a directory it does not
  # write: the attribute would be silently dropped on the way to the manifest, and the declaration
  # would go on saying something the cluster never heard.
  probeAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry selected;
        shapes = probeShapesOf entry;
        stray = lib.subtractLists (lib.attrNames shapes) (lib.attrNames w.probes);
      in
      [{
        assertion = stray == [ ];
        message =
          "${namespace}: workload `${name}` budgets "
          + lib.concatMapStringsSep ", " (k: "`${k}`") stray
          + ", which `${selected}` does not warrant. It warrants: "
          + (if shapes == { } then "no probes at all"
          else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames shapes))
          + ". A budget for a probe that is never rendered is a number nothing reads.";
      }])
    workloads;

  # Both directions, because both are real mistakes. A workload that reads credentials and names
  # no Secret starts without them and fails later, further from the cause; a workload that reads
  # none and names one has a reference nothing consumes, which is a typo wearing a declaration's
  # clothes.
  credentialAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry selected;
        vars = entry.credentials or [ ];
        reads = vars != [ ];
        named = w.credentials.secret != null || w.credentials.secrets != { };
        uncovered = lib.filter (v: secretFor w v == null) vars;
        stray = lib.subtractLists vars
          (lib.unique (lib.attrNames w.credentials.keys ++ lib.attrNames w.credentials.secrets));
      in
      [
        {
          assertion = if reads then uncovered == [ ] else !named;
          message =
            if reads
            then
              "${namespace}: workload `${name}` reads "
              + lib.concatMapStringsSep ", " (v: "`${v}`") uncovered
              + " from its environment and names no Secret to deliver "
              + (if lib.length uncovered == 1 then "it" else "them")
              + ". This repository cannot carry their content, so the Secret's NAME is the one half "
              + "a declaration owes -- as `credentials.secret` for all of them, or "
              + "`credentials.secrets.<VARIABLE>` for one that comes from somewhere else."
            else
              "${namespace}: workload `${name}` names a Secret, and `${selected}` reads no "
              + "credential from its environment. A reference nothing consumes is a typo, not a "
              + "declaration.";
        }
        {
          assertion = stray == [ ];
          message =
            "${namespace}: workload `${name}` maps a key for "
            + lib.concatMapStringsSep ", " (v: "`${v}`") stray
            + ", which `${selected}` does not read. A key mapping renames the KEY inside the "
            + "Secret for a variable the software already looks in; it cannot invent the variable.";
        }
      ])
    (lib.filter (x: usesCommonOption x.spec "credentials") workloads);

  # ONE OF THE TWO WAYS OF SAYING WHAT RUNS, and exactly one. Neither is a default anybody could
  # supply: a catalogue naming a version would be guessing at somebody else's cluster, and a
  # workload with no reference at all is one nothing can start.
  imageAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry selected; in
      [{
        assertion = w.image != null || w.version != null;
        message =
          "${namespace}: workload `${name}` says neither which version it runs nor a whole image "
          + "reference. One of them decides what starts, and there is no third place for that to "
          + "come from.";
      }
      {
        # The catalogue's half of the same question, checked so the failure is this sentence
        # rather than a coercion error thrown while building a tag out of null.
        assertion = (entry.image or null) != null || w.image != null;
        message =
          "${namespace}: workload `${name}` runs `${selected}`, which nobody publishes an "
          + "image for -- the catalogue holds a build recipe rather than a repository, so a "
          + "version has nothing to be a tag OF. This declaration must carry a whole image "
          + "reference, for a container somebody built.";
      }])
    workloads;

  # IDLING IS A CORRECTNESS QUESTION, not a preference, which is why this refuses rather than
  # warns. A catalogue says a workload is unsafe to idle when it has work that happens while nobody
  # is looking -- a timer, a queue, a directory watch. Scaling that to zero does not make it slow,
  # it makes it silently not happen.
  # THE CATALOGUE SAYS HOW LOUD, AND WHY. Two repositories disagreed about idle-safety and both
  # were right for their own software: one refuses it, one warns. Centralising on a single fixed
  # message would have made that a coin-toss and thrown away the better sentence -- the guard that
  # reads "the request that would have woken it is the request that was supposed to be delivered"
  # tells somebody what went wrong; "idle whatever fronts it instead" tells them a rule.
  #
  # So a catalogue may state a severity, and may state the reason in its own words. The factory
  # owns the CHECK; the catalogue owns how hard it bites and what it says about this software.
  severityOf = entry: field: default:
    let v = entry.${field} or null; in
    if v == null || !(lib.isAttrs v) then default else (v.severity or default);

  becauseOf = entry: field:
    let v = entry.${field} or null; in
    if v == null || !(lib.isAttrs v) then null else (v.because or null);

  # A catalogue's own sentence, appended to the factory's. Never replacing it: the generic half
  # says which rule fired, which is what makes a message searchable across thirteen repositories.
  withBecause = entry: field: message:
    let b = becauseOf entry field; in
    message + lib.optionalString (b != null) (" " + b);

  # `idleSafe = false` and `idleSafe = { safe = false; severity = "warn"; because = "..."; }` are
  # the same fact stated at two volumes. The bare boolean refuses, because that is the answer that
  # protects work nobody is watching; a catalogue that has measured its own software and knows the
  # loss is tolerable says so explicitly.
  idleSafeOf = entry:
    let v = entry.idleSafe or true; in
    if lib.isAttrs v then (v.safe or true) else v;

  idleUnsafe = x: x.w.scaling == "scale-to-zero" && !(idleSafeOf x.entry);

  idleMessage = x:
    withBecause x.entry "idleSafe"
      ("${namespace}: workload `${x.name}` is declared scale-to-zero, and `${x.selected}` is "
        + "catalogued as unsafe to idle -- it has work that happens while nobody is looking. At "
        + "zero replicas that work does not happen late, it does not happen.");

  idleAssertions = map
    (x: { assertion = !(idleUnsafe x); message = idleMessage x; })
    (lib.filter (x: severityOf x.entry "idleSafe" "refuse" == "refuse") workloads);

  idleWarnings = map
    (x: { when = idleUnsafe x; message = idleMessage x; })
    (lib.filter (x: severityOf x.entry "idleSafe" "refuse" == "warn") workloads);

  # Both directions again. A dependency the catalogue names and the declaration leaves out is a
  # workload started without knowing where something is; one the declaration names and the
  # catalogue does not know about is a URL nothing will ever read.
  requiresAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry selected;
        catalogued = lib.attrNames (entry.requires or { });
        declared = lib.attrNames w.requires;
        missing = lib.subtractLists declared catalogued;
        stray = lib.subtractLists catalogued declared;
        shared = lib.filter (k: lib.elem k catalogued) declared;
        literals = lib.filter (k: isAddress (w.requires.${k}).endpoint) shared;
        wrongScheme = lib.filter
          (k:
            let want = (entry.requires.${k}).scheme or null; in
            want != null && !lib.hasPrefix "${want}://" (w.requires.${k}).endpoint)
          shared;
      in
      [
        {
          assertion = missing == [ ];
          message =
            "${namespace}: workload `${name}` needs "
            + lib.concatMapStringsSep ", " (k: "`${k}`") missing
            + " and is not told where to find "
            + (if lib.length missing == 1 then "it" else "them")
            + ". A workload that starts without knowing where its dependency is fails later and "
            + "further from the cause than one that is refused here.";
        }
        {
          assertion = stray == [ ];
          message =
            "${namespace}: workload `${name}` is told where to find "
            + lib.concatMapStringsSep ", " (k: "`${k}`") stray
            + ", which `${selected}` does not read. An endpoint nothing consumes is a typo, "
            + "not a declaration.";
        }
        {
          # WHAT IS SPOKEN on the other end, when the catalogue knows. A queue reached over `http://`
          # and an index reached over `redis://` are both plausible strings and neither works, and
          # the failure arrives at the first request rather than at the render.
          assertion = wrongScheme == [ ];
          message =
            "${namespace}: workload `${name}` is given an endpoint for "
            + lib.concatMapStringsSep ", " (k: "`${k}`") wrongScheme
            + " that does not speak the protocol `${selected}` expects there. The catalogue "
            + "says which scheme belongs on each of these, because that is a property of the "
            + "software rather than of one cluster's routing.";
        }
        {
          assertion = literals == [ ];
          message =
            "${namespace}: workload `${name}` is given a literal ADDRESS for "
            + lib.concatMapStringsSep ", " (k: "`${k}`") literals
            + ". An address is one network on one day: name the service instead, or the workload "
            + "goes on holding a number nothing answers on and fails silently when it changes.";
        }
      ])
    workloads;

  # NESTED MOUNTS ARE ORDERED, AND THE ORDER IS THE CATALOGUE'S KEY NAMES.
  #
  # A workload that keeps one directory inside another -- an index at /data and the archive itself
  # at /data/archive -- gets both as separate mounts, and they are rendered in attribute order. If
  # the INNER name sorts first it is written first and the outer one is laid on top of it: the
  # archive is still on the disk and the application can no longer see it. Nothing fails, nothing
  # logs, and the workload comes up looking healthy against an empty directory.
  #
  # It is checked here rather than in each catalogue because it is a property of how mounts render,
  # which no catalogue can see, and the fix is always the same -- rename the keys so the outer one
  # sorts first.
  nestingAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        keys = sharedStateKeys entry w;
        pathOf = k: mountPathOf entry.state.${k};
        # EVERY path of a multi-mount volume, because a volume mounted at four places can cover
        # another one at any of them, and checking only the first is checking one case in four.
        nests = outer: inner:
          lib.any (o: lib.any (i: lib.hasPrefix "${o}/" i) (pathsOfEntry entry.state.${inner}))
            (pathsOfEntry entry.state.${outer});
        pairs = lib.concatMap
          (outer: lib.concatMap
            (inner:
              lib.optional
                (outer != inner
                  && nests outer inner
                  && volumeNameOf x inner < volumeNameOf x outer)
                { inherit outer inner; })
            keys)
          keys;
      in
      map
        (c: {
          # ONLY when the CATALOGUE's own key names sort wrong. That is a bug in the catalogue and
          # nobody's cluster can be relying on it. A pair that sorts wrong only because a
          # DECLARATION renamed a volume is a different situation entirely -- the live object
          # already carries that name, so refusing would make it impossible to adopt a cluster's
          # own history, and the render would be refusing something already running. That case
          # warns; see below.
          assertion = !(c.inner < c.outer);
          message =
            "${namespace}: workload `${name}` mounts `${c.inner}` (${pathOf c.inner}) inside "
            + "`${c.outer}` (${pathOf c.outer}), and the CATALOGUE's names sort the wrong way "
            + "round. Mounts are rendered in attribute order, so `${c.inner}` would be written "
            + "first and `${c.outer}` laid on top of it -- the data is still on the disk and the "
            + "workload can no longer see it. Rename the keys so the outer one sorts first.";
        })
        pairs)
    commonStateWorkloads;

  # The same collision, caused by a rename rather than by the catalogue. It warns because a rename
  # records what a live object is ALREADY called: refusing would make an existing cluster
  # undeclarable, which is not the same service as catching a mistake.
  nestingWarnings = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        keys = sharedStateKeys entry w;
        pathOf = k: mountPathOf entry.state.${k};
        nests = outer: inner:
          lib.any (o: lib.any (i: lib.hasPrefix "${o}/" i) (pathsOfEntry entry.state.${inner}))
            (pathsOfEntry entry.state.${outer});
        renamed = lib.concatMap
          (outer: lib.concatMap
            (inner:
              lib.optional
                (outer != inner
                  && nests outer inner
                  && !(inner < outer)
                  && volumeNameOf x inner < volumeNameOf x outer)
                { inherit outer inner; })
            keys)
          keys;
      in
      map
        (c: {
          when = true;
          message =
            "${namespace}: workload `${name}` renames `${c.inner}` to "
            + "`${volumeNameOf x c.inner}`, which now sorts before `${volumeNameOf x c.outer}` -- "
            + "the volume covering it at ${pathOf c.outer}. Mounts render in that order, so the "
            + "outer one is laid over the inner and its data stops being visible. The names are "
            + "presumably what the live objects already carry, which is why this is not refused.";
        })
        renamed)
    commonStateWorkloads;

  # WHO IT RUNS AS, refused in both directions. An image that can only start as uid 0 and a
  # declaration that names a role are each individually sensible and together are a contradiction:
  # the role would be silently ignored, which is the worst outcome -- somebody believes they
  # dropped privileges. And an image that reads its ids from the environment with no role to read
  # gets no ids at all, so it runs as whatever the image's own USER is while the declaration looks
  # like it decided something.
  identityAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry selected; in
      [
        {
          # ONLY when there is no environment path for the role to arrive by. An image that starts
          # as root AND reads its ids from the environment is the ordinary drop-privileges pattern:
          # it needs uid 0 to do its setup and then becomes the role it was handed. That is not a
          # contradiction, it is how the role gets used. The contradiction is a root-start image
          # with NO such variable, where the role reaches nothing at all.
          assertion =
            !((entry.rootStart or false)
              && w.identity != null
              && (entry.identityEnv or null) == null);
          message =
            "${namespace}: workload `${name}` names the identity `${toString w.identity}`, and "
            + "`${selected}` can only START as uid 0 with no variable to read a role from. The "
            + "role would be ignored rather than applied, which is worse than refusing it: somebody "
            + "would believe this pod was unprivileged.";
        }
        {
          assertion = (entry.identityEnv or null) == null || w.identity != null;
          message =
            "${namespace}: workload `${name}` runs software that reads its own user and group ids "
            + "from its environment, and no identity is named for it to read. It would start as "
            + "whatever the image's own USER is, while this declaration looks like it decided.";
        }
      ])
    workloads;

  # ── The other containers, refused in both directions ─────────────────────────────────────────
  containerAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry selected;
        comps = entry.companions or { };
        inits = entry.init or [ ];
        ownImage = c: (c.image or null) != null;

        compsOwn = lib.attrNames (lib.filterAttrs (_: ownImage) comps);
        compsShared = lib.attrNames (lib.filterAttrs (_: c: !(ownImage c)) comps);
        initsOwn = map (c: c.name) (lib.filter ownImage inits);
        initsShared = map (c: c.name) (lib.filter (c: !(ownImage c)) inits);

        missingCompImage = lib.subtractLists (lib.attrNames w.companionImages) compsOwn;
        strayCompImage = lib.subtractLists compsOwn (lib.attrNames w.companionImages);
        missingInitImage = lib.subtractLists (lib.attrNames w.initImages) initsOwn;
        strayInitImage = lib.subtractLists initsOwn (lib.attrNames w.initImages);
        straySizing =
          if usesCommonOption x.spec "companionResources"
          then lib.subtractLists (lib.attrNames comps) (lib.attrNames w.companionResources)
          else [ ];

        initNames = map (c: c.name) inits;
        podNames = [ (if w.objectName != null then w.objectName else name) ]
          ++ lib.attrNames comps ++ initNames;
      in
      [
        {
          assertion = missingCompImage == [ ] && missingInitImage == [ ];
          message =
            "${namespace}: workload `${name}` has containers that run an image of their own ("
            + lib.concatMapStringsSep ", " (k: "`${k}`") (missingCompImage ++ missingInitImage)
            + ") and no reference was given for "
            + (if lib.length (missingCompImage ++ missingInitImage) == 1 then "it" else "them")
            + ". The catalogue holds the repository; which BUILD of it runs is a deployment's, "
            + "exactly as it is for the application's own image -- and the fallback is the bare "
            + "untagged repository, which is two syncs of one rendered tree running different code.";
        }
        {
          assertion = strayCompImage == [ ] && strayInitImage == [ ];
          message =
            "${namespace}: workload `${name}` gives an image for "
            + lib.concatMapStringsSep ", " (k: "`${k}`") (strayCompImage ++ strayInitImage)
            + ", which is not a container of `${selected}` that runs an image of its own. A "
            + "container that shares the application's installation shares its image; a name that "
            + "is neither is a typo, and a typo here renders a container nobody declared.";
        }
        {
          assertion = straySizing == [ ];
          message =
            "${namespace}: workload `${name}` sizes "
            + lib.concatMapStringsSep ", " (k: "`${k}`") straySizing
            + ", which is not a container of `${selected}`. A request against a container "
            + "that does not exist is a number the scheduler never sees, in a declaration that "
            + "reads as though somebody had measured it.";
        }
        {
          # The kubelet keys containers by name and so does every overlay written against them.
          assertion = lib.length (lib.unique podNames) == lib.length podNames;
          message =
            "${namespace}: workload `${name}` has two containers of one name in a single pod ("
            + lib.concatStringsSep ", " podNames
            + "). The kubelet keys them by name, so that is one container that runs and one that "
            + "quietly does not.";
        }
      ])
    workloads;

  # A RENAMED VOLUME MUST STILL BE A NAME. `volumeName` exists to match what a live object already
  # calls a volume, and that name is an RFC 1123 DNS label. Anything else renders perfectly and is
  # rejected by the API server at apply time, which is the worst place to find out.
  isDnsLabel = n:
    n != "" && lib.stringLength n <= 63
    && builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" n != null;

  volumeNameAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w;
        bad = lib.filter (k: !(isDnsLabel (volumeNameOf x k))) (lib.attrNames w.state);
      in
      [{
        assertion = bad == [ ];
        message =
          "${namespace}: workload `${name}` renames "
          + lib.concatMapStringsSep ", " (k: "`${k}` to `${volumeNameOf x k}`") bad
          + ", which Kubernetes will not accept as a name -- lowercase letters, digits and dashes, "
          + "starting and ending with a letter or a digit. This renders and then fails at apply.";
      }])
    commonStateWorkloads;

  # WHAT IT ASKS OF WHOEVER REACHES IT, against how far it is published. The same shape as the idle
  # guard: a catalogue fact crossed with a declaration's choice. Software that authenticates nobody,
  # published, is readable and rewritable by whoever finds it -- and an exposure class is a property
  # of the WORKLOAD, so there is no publishing half of it and no port to publish on its own.
  authUnsafe = x: !(authenticatesOf x.entry) && (x.w.exposure or "internal") == "public";

  authenticatesOf = entry:
    let v = entry.authenticates or true; in
    if lib.isAttrs v then (v.authenticates or true) else v;

  authMessage = x:
    withBecause x.entry "authenticates"
      ("${namespace}: workload `${x.name}` is declared `public`, and `${x.selected}` asks "
        + "nobody for anything -- there is no login on it at all, so whoever reaches it can read "
        + "and rewrite everything in it.");

  authAssertions = map
    (x: { assertion = !(authUnsafe x); message = authMessage x; })
    (lib.filter (x: severityOf x.entry "authenticates" "refuse" == "refuse") workloads);

  authWarnings = map
    (x: { when = authUnsafe x; message = authMessage x; })
    (lib.filter (x: severityOf x.entry "authenticates" "refuse" == "warn") workloads);

  # TWO COPIES OF A SINGLE WRITER IS NOT A SCALING DECISION. The catalogue knows whether the
  # software tolerates it; nothing about one cluster's load changes the answer.
  replicaAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry selected; in
      [{
        assertion = w.replicas == null || w.replicas <= 1 || !(entry.singleWriter or false);
        message =
          "${namespace}: workload `${name}` asks for ${toString w.replicas} copies, and "
          + "`${selected}` is catalogued as a single writer -- it holds a store that exactly "
          + "one process may have open. A second copy does not share the load, it corrupts the "
          + "store, and the symptom arrives long after the change that caused it.";
      }])
    workloads;

  # A public URL nothing reads is not harmless -- it is somebody believing they configured a link
  # base. The catalogue decides whether this software has one to configure.
  publicUrlAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry selected; in
      [{
        assertion = w.publicUrl == null || (entry.selfUrlEnv or null) != null;
        message =
          "${namespace}: workload `${name}` is given a public URL, and `${selected}` reads no "
          + "variable to carry one. Nothing would consume it, so nothing would go wrong visibly -- "
          + "which is the whole reason this is an error rather than an unused value.";
      }
      {
        # The other direction, and the one that actually breaks things. Software that generates
        # links to itself and has not been told what it is called generates wrong ones: a
        # confirmation mail nobody can follow, a redirect to localhost.
        assertion = (entry.selfUrlEnv or null) == null || w.publicUrl != null;
        message =
          "${namespace}: workload `${name}` generates links to itself and has not been told what "
          + "it is called. It will generate them anyway, from whatever it can guess -- which is how "
          + "a confirmation mail arrives pointing at a host nobody can reach.";
      }
      {
        # A URL is a name. The same argument as `requires`, for the same reason.
        assertion = w.publicUrl == null || !isAddress w.publicUrl;
        message =
          "${namespace}: workload `${name}` is told it lives at a literal ADDRESS. Every link it "
          + "generates would carry that number, into mails and bookmarks that outlive the lease on "
          + "it.";
      }])
    workloads;

  # A namespace outlives every workload in it, so exactly one thing may own it. Two anchors is not
  # a merge, it is two Namespace objects the delivery controller will fight over.
  anchorAssertions =
    let
      # Only the grammar can stamp a Namespace with prune protection. Dispatch assertions below
      # refuse this flag on the other kinds; do not let those invalid declarations count as owners
      # while collecting the cross-root uniqueness guard.
      anchors = lib.filter (x: x.spec.createNamespaceOf x) workloads;
      byNs = lib.groupBy (x: x.spec.namespaceOf x) anchors;
    in
    lib.mapAttrsToList
      (ns: xs: {
        assertion = lib.length xs == 1;
        message =
          "${namespace}: namespace `${ns}` is anchored by ${toString (lib.length xs)} workloads ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). Exactly one workload may create a namespace.";
      })
      byNs;

  slotAssertions =
    let
      claimed = lib.filter (x: (x.w.slot or null) != null) allWorkloads;
      bySlot = lib.groupBy (x: toString x.w.slot) claimed;
    in
    lib.mapAttrsToList
      (slot: xs: {
        assertion = lib.length xs == 1;
        message =
          "${namespace}: slot ${slot} is claimed by ${toString (lib.length xs)} workloads ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). A slot is one identity in several address spaces at once; two workloads on one "
          + "number is two workloads on one address.";
      })
      bySlot;

  # ── Root and rendering-kind dispatch ────────────────────────────────────────────────────────
  #
  # These are factory invariants, before any domain-specific interlock. A callback returning a
  # misspelt kind must fail with a sentence rather than silently putting the declaration in no
  # partition; an app carrying whole manifests must not render two competing copies; and a direct
  # manifest may not create a Namespace because this lower-level renderer cannot stamp the
  # grammar's prune protection on it.
  showKind = kind: if lib.isString kind then kind else "<${builtins.typeOf kind}>";

  dispatchAssertions = lib.concatMap
    (x: [
      {
        assertion = lib.isString x.kind && lib.elem x.kind [ "app" "manifest" "reference" ];
        message =
          "${namespace}: `${x.root}.${x.name}` dispatches catalogue entry `${x.selected}` to "
          + "unknown rendering kind `${showKind x.kind}`. The kinds are `app`, `manifest`, and "
          + "`reference`; an unknown kind renders nothing and is therefore refused.";
      }
      {
        assertion = !(isKind "app" x) || x.spec.manifestsOf x == [ ];
        message =
          "${namespace}: `${x.root}.${x.name}` is rendered in full by the app grammar and also "
          + "carries whole manifests. That is two authorities for the same workload; put extra "
          + "objects in the grammar's countable `raw` hatch instead.";
      }
      {
        assertion = !(isKind "reference" x) || x.spec.manifestsOf x == [ ];
        message =
          "${namespace}: `${x.root}.${x.name}` is a reference and carries manifests. A reference "
          + "exists precisely because this environment does not deliver it, so rendering objects "
          + "under that declaration would contradict its catalogue kind.";
      }
      {
        assertion =
          !(isKind "manifest" x || isKind "reference" x)
          || !(x.spec.createNamespaceOf x);
        message =
          "${namespace}: `${x.root}.${x.name}` is a `${showKind x.kind}` delivery and tries to create "
          + "namespace `${x.spec.namespaceOf x}`. A non-grammar renderer cannot stamp the grammar's "
          + "prune protection on a Namespace -- and a reference renders no object at all. Anchor "
          + "the namespace through a grammar app or tenancy instead.";
      }
    ]) allWorkloads;

  declarationNameAssertions =
    let byName = lib.groupBy (x: x.name) allWorkloads; in
    lib.mapAttrsToList
      (name: xs: {
        assertion = lib.length xs == 1;
        message =
          "${namespace}: declaration name `${name}` appears in more than one root ("
          + lib.concatMapStringsSep ", " (x: "`${x.root}`") xs
          + "). Roots are user-facing catalogue tables, not separate Kubernetes name scopes; one "
          + "name would overwrite another Application.";
      })
      byName;

  renderedWorkloads = workloads ++ lib.filter (x: x.spec.manifestsOf x != [ ]) manifestWorkloads;
  renderNameAssertions =
    let byName = lib.groupBy renderNameOf renderedWorkloads; in
    lib.mapAttrsToList
      (name: xs: {
        assertion = lib.length xs == 1;
        message =
          "${namespace}: rendered name `${name}` is produced by more than one declaration ("
          + lib.concatMapStringsSep ", " (x: "`${x.root}.${x.name}`") xs
          + "). A grammar app and a manifest Application cannot own one Argo CD identity.";
      })
      byName;

  # The grammar keeps its module key at the declaration name while `app.name` may adopt a live
  # object name. Direct Applications are keyed by the resolved name. Check that module-key space
  # separately from rendered identity: otherwise `applications.web` from each route can merge into
  # one malformed Application even when the two objects' resolved names differ.
  applicationKeyOf = x: if isKind "app" x then x.name else renderNameOf x;
  applicationKeyAssertions =
    let byName = lib.groupBy applicationKeyOf renderedWorkloads; in
    lib.mapAttrsToList
      (name: xs: {
        assertion = lib.length xs == 1;
        message =
          "${namespace}: Application option key `${name}` is produced by more than one declaration ("
          + lib.concatMapStringsSep ", " (x: "`${x.root}.${x.name}`") xs
          + "). Grammar Applications keep the declaration key even when `nameOf` resolves their "
          + "object name; a direct Application may not merge into that module subtree.";
      })
      byName;

  rootAssertions = lib.concatLists (lib.mapAttrsToList
    (rootName: spec: spec.assertions (lib.filter (x: x.root == rootName) allWorkloads))
    rootSpecs);

  rootWarnings = lib.concatLists (lib.mapAttrsToList
    (rootName: spec: spec.warnings (lib.filter (x: x.root == rootName) allWorkloads))
    rootSpecs);

  dispatchWarnings = map
    (x: {
      when = x.spec.manifestsOf x == [ ];
      message =
        "${namespace}: `${x.root}.${x.name}` is a manifest delivery with no manifests, so this "
        + "factory renders no Application for it. That is correct only when another module in the "
        + "same environment delivers the object; the declaration remains available to interlocks.";
    })
    manifestWorkloads;

  # A warning is `{ when; message; }` — the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  builtinWarnings = lib.concatMap
    (x:
      let inherit (x) name w entry selected; in
      [
        {
          when = usesCommonOption x.spec "wake"
            && w.scaling == "scale-to-zero"
            && w.wake == null;
          message =
            "${namespace}: workload `${name}` is declared scale-to-zero with no wake front, so "
            + "nothing brings it back. At zero replicas that is not an idle workload, it is an "
            + "unreachable one.";
        }
        {
          # A container that asks for nothing is SCHEDULED as though it were free, which is how a
          # node ends up oversubscribed by workloads that each looked small. Nothing fills it in:
          # a number nobody measured is worse than an honest absence, and this keeps the absence
          # countable instead of invisible.
          when = usesCommonOption x.spec "resources"
            && w.resources.cpuRequest == null
            && w.resources.memoryRequest == null;
          message =
            "${namespace}: workload `${name}` asks for no CPU or memory, so the scheduler places it "
            + "as if it cost nothing. Nothing here fills that in -- a number nobody measured would "
            + "be a guess the scheduler then treats as a measurement.";
        }
        {
          when = usesCommonOption x.spec "image" && w.image != null;
          message =
            "${namespace}: workload `${name}` carries a whole image reference, so the `version` "
            + "beside it now chooses nothing -- the reference decides what runs. Keep them agreeing "
            + "anyway: the version is what a reader looks at, and a stale one is a reader misled by "
            + "a declaration that is technically correct.";
        }
        {
          when = (w.slot or null) != null && platform.origin == null;
          message =
            "${namespace}: workload `${name}` claims slot ${toString (w.slot or null)}, and "
            + "`${optionPathText}.${platformOption}.origin` is unset — so the number is checked for "
            + "collisions inside this repository and by nothing for which RANGE it may come from.";
        }
        {
          when = usesCommonOption x.spec "harden"
            && !w.harden
            && ((entry.hardening or null) != null);
          message =
            "${namespace}: workload `${name}` renders no securityContext, and `${selected}` is "
            + "catalogued with hardening classes it tolerates. The pod is therefore looser than the "
            + "software requires. That is a legitimate ADOPTION position — a live pod acquires these "
            + "fields by being replaced — and it is not a resting place.";
        }
      ])
    workloads;

  # ── The declaration's own vocabulary ─────────────────────────────────────────────────────────

  # The BUDGET half of a probe. Every field is `null` by default and `null` means "the
  # catalogue's", so a declaration states only the numbers it is actually changing and a reader can
  # tell the two apart. Which endpoint is probed, on which port, is NOT here: that is what the
  # probe asks, and what software answers on does not vary by cluster.
  probeBudgetType = lib.types.submodule {
    options = {
      periodSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "How often this cluster asks. Null takes the catalogue's interval.";
      };
      failureThreshold = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          How many consecutive failures this cluster absorbs before acting. Together with
          `periodSeconds` this is the whole patience budget, and it is the number that decides
          whether a slow start is tolerated or restarted into another slow start.
        '';
      };
      timeoutSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          How long ONE answer may take. Normally the catalogue's, because it is a property of the
          software answering rather than of the cluster asking — overridable because a cluster
          whose storage is slower makes the same software answer slower.
        '';
      };
      initialDelaySeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = ''
          Delay before the first probe. Purely a deployment's, and almost always wrong: a startup
          probe expresses "not yet" far better, because it stops waiting the moment the app
          answers instead of always waiting the whole time.
        '';
      };
    };
  };

  backingType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "An existing PersistentVolumeClaim, by name. Nothing here creates one.";
      };
      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "A directory on the node. Pins the workload to whichever node holds it.";
      };
      configMap = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "An existing ConfigMap, by name, mounted as files. Nothing here creates one.";
      };
      secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          An existing Secret, by name, mounted as files. Nothing here creates one and nothing here
          can carry its content -- this names it, exactly like `credentials` does.
        '';
      };
      emptyDir = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          A scratch directory that lives and dies with the pod. The right answer for a cache and
          the wrong one for anything a restart must survive, which is why it is a backing somebody
          chooses rather than the thing you get by saying nothing.
        '';
      };
      ownership = lib.mkOption {
        type = lib.types.enum [ "site-curated" "kubelet" ];
        default = "site-curated";
        description = ''
          WHO OWNS THE FILES, which decides whether anything chowns them. `site-curated` -- the
          default -- means somebody outside the cluster owns this directory and nothing here
          touches it. `kubelet` renders the resolved identity's fsGroup on the pod.

          THE DEFAULT IS THE LOAD-BEARING HALF. fsGroup makes the kubelet RECURSIVELY CHOWN the
          volume on EVERY pod start: on a claim nothing else touches that is merely slow, and on a
          node path somebody curates outside the cluster it destroys ownership set there
          deliberately. A catalogue that says a directory GROWS refuses it outright.
        '';
      };
      volumeName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          What the rendered volume is CALLED, when the live object already calls it something else.
          Purely a cluster's history: a workload adopted from a hand-written manifest carries
          whatever name somebody typed, and renaming a volume in place is a rollout rather than an
          edit. Null takes the catalogue's own name for the directory.
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
          The hostPath type, when a node path is what backs it. `Directory` — the default, and the
          same default the grammar underneath uses — refuses to start the pod when the path is
          missing. `DirectoryOrCreate` makes an empty one instead, which for a workload whose whole
          state is one database file means coming up looking healthy with no data.
        '';
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the mount is read-only. A catalogue that states read-only for a directory wins
          over this, because "this software only ever reads it" is knowledge rather than a choice.
        '';
      };
    };
  };

  # The four scalars, named once: what the app's own container costs and what a companion costs
  # are the same question asked about a different container.
  resourceScalars = {
    cpuRequest = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10m";
      description = ''
        CPU the scheduler must find for this container. A REQUEST is what placement is computed
        from, and a container with none is placed as if it were free.
      '';
    };
    memoryRequest = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "16Mi";
      description = "Memory the scheduler must find for this container.";
    };
    cpuLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        CPU ceiling. A CPU limit is a THROTTLE rather than a kill threshold, which is usually not
        what anybody wants -- an app that briefly needs more is made slower rather than stopped.
      '';
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "256Mi";
      description = ''
        Memory ceiling, which IS a kill threshold -- usually what a leaky application wants, and
        the reason this one is worth setting where the CPU one is not.
      '';
    };
  };

  commonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Which version this workload runs, used as the image tag alongside the catalogue's
        repository.

        THIS AND `image` ARE ALTERNATIVES rather than a pair: a whole reference already says what
        runs, and a version beside one chooses nothing. Stating NEITHER is refused -- there would
        be no way to know what to run, and defaulting it would be a guess about somebody else's
        cluster wearing a value's clothes.
      '';
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Whole image reference, replacing the catalogue's repository plus `version`. Set it to PIN
        BY DIGEST, which is the only way two syncs of an identical rendered tree cannot run
        different code — the grammar warns while it is unpinned.
      '';
    };

    manifests = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Whole objects delivered under this workload's Application when its catalogue entry
        dispatches to the `manifest` kind. The factory treats rendered charts and custom resources
        alike: both are opaque YAML whose schema belongs to the producer, not to nixk3s.

        Refused on `app` and `reference` entries. An empty list on a manifest entry deliberately
        renders no Application and warns; that is the supported declaration for something another
        module in the same environment delivers.
      '';
    };

    companionImages = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Whole image references for companions that run an image OF THEIR OWN, keyed by the
        catalogue's name for the companion. Required for exactly those, and refused for the ones
        that share the application's installation: a process shipping inside the app's own image
        has no second build to pin, and naming one is a typo that renders a container nobody
        declared.
      '';
    };

    companionResources = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { options = resourceScalars; });
      default = { };
      description = ''
        What each companion costs on this hardware, keyed by the catalogue's name for it. One
        nobody sized asks for nothing, which renders no resources block at all rather than a zero
        -- a different and much worse claim.
      '';
    };

    initImages = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Whole image references for init steps that run an image of their own, keyed by the
        catalogue's name for the step. Same rule as `companionImages`, for the same reason: a step
        running the application's own image is pinned by the application's own reference, and a
        step running a tool is pinned by whoever chose the tool.
      '';
    };

    objectName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        What the rendered objects are CALLED, when the live ones are called something other than
        this declaration's key. Purely a cluster's history -- renaming an object in place is a
        delete and a create, not an edit -- which is why it sits here and not in the catalogue.
      '';
    };

    replicas = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        How many copies run. Null leaves it to the platform, which is the honest default: a number
        here is a claim that this software tolerates being run more than once, and most of what
        this family catalogues does not.

        Refused outright on software the catalogue marks `singleWriter`, because two copies of
        that is not a scaling decision, it is two processes writing one store.
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = platform.namespace;
      defaultText = lib.literalExpression "config.${optionPathText}.${platformOption}.namespace";
      description = "Namespace this workload lands in.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload anchors its namespace. Defaults to false, because workloads share a
        namespace by default and exactly one of them may own it.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.${optionPathText}.${platformOption}.project";
      description = "Delivery project this workload's Application belongs to.";
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address —
        the layers underneath map it into however many address spaces the fleet keeps, which is
        why nothing here moves one. The VALUE is a fleet fact and belongs to the consumer.
      '';
    };

    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        Who can reach it, as a CLASS rather than an address. Defaults to the closed answer: a
        workload nobody has thought about is not on the internet.
      '';
    };

    scaling = lib.mkOption {
      type = lib.types.enum [ "always" "scale-to-zero" ];
      default = "always";
      description = ''
        Whether the workload may idle to zero replicas. The catalogue records whether sleeping is
        SAFE; whether it is WANTED is a deployment's call, because the wake path is one cluster's
        routing and a catalogue cannot see whether that path is healthy.
      '';
    };

    wake = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
      default = null;
      description = ''
        Which front wakes it from zero. Meaningless unless `scaling = "scale-to-zero"`, and its
        absence there is warned about: nothing brings the workload back.
      '';
    };

    adopt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload TAKES OVER objects that already exist in the cluster, rather than
        creating them. Renders the Application with server-side apply and server-side diff, so the
        delivery controller compares against what the API server actually holds instead of against
        a client-side reconstruction of it.

        IT IS A DEPLOYMENT'S FACT AND NOT THE CATALOGUE'S. Whether a Deployment of this name is
        already running — applied by an addon, by hand, or by the manifest this declaration
        replaces — is that cluster's HISTORY, not anything true about the software.

        It shrinks the diff; it does not make it zero. A rendered spec is never byte-identical to
        the YAML it replaces, and for a workload whose `state` forces `Recreate` a remaining diff
        is a sync and a sync is downtime. Render it, diff it against what is live, and decide
        knowingly.
      '';
    };

    harden = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to stamp the catalogue's hardening classes onto this pod.

        THE CLASSES ARE NOT DECLARABLE, and that is the point of the split: "needs no Linux
        capability", "never regains privilege", "runs under the default seccomp profile" are facts
        about the software, so they live in the catalogue and a deployment cannot loosen them by
        writing a different value. What a deployment genuinely owns is WHETHER the fields are
        rendered at all — a pod acquires a securityContext by being REPLACED, so an adoption
        renders exactly the subset its live objects already carry and turns the rest on in a commit
        that is allowed to roll.

        Defaults to true: the restrictive answer is the one you get for free, and the loose one is
        the one somebody has to type — and typing it warns, so it stays countable.
      '';
    };

    state = lib.mkOption {
      type = lib.types.attrsOf backingType;
      default = { };
      description = ''
        What backs each directory the catalogue says this workload writes, keyed by the SAME names.
        Backing a directory it does not write, or leaving one it does write unbacked, is an eval
        error rather than a surprise at runtime.
      '';
    };

    probes = lib.mkOption {
      type = lib.types.attrsOf probeBudgetType;
      default = { };
      example = lib.literalExpression ''{ startup.failureThreshold = 60; }'';
      description = ''
        THIS CLUSTER'S PATIENCE, keyed by the probe the catalogue already warrants. Everything
        unstated is the catalogue's, so a declaration carries only the numbers that differ here —
        and budgeting a probe the software does not warrant is an eval error rather than an
        attribute silently dropped on the way to the manifest.

        The case this exists for is not fine-tuning. It is a workload woken from zero with a
        request already held open, or a node whose disk is slow enough that the software's own
        patience is no longer enough: both are the CLUSTER being slow, not the software.
      '';
    };

    resources = resourceScalars;

    credentials = {
      secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The NAME of an existing Secret delivering every credential variable the catalogue says
          this software reads. Nothing here creates it and nothing here can carry its content,
          which is what makes a declaration written against this module safe to publish.
        '';
      };
      keys = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = lib.literalExpression ''{ DB_PASSWORD = "postgres-password"; }'';
        description = ''
          Per-variable overrides of the KEY inside the Secret, as `<VARIABLE> = "<key>"`. Defaults
          to the variable's own name. It renames the key for a variable the software already reads;
          it cannot invent the variable, and naming one the catalogue does not list is an error.
        '';
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = lib.literalExpression ''{ SMTP_PASSWORD = "shared-mail-credentials"; }'';
        description = ''
          Per-variable overrides of WHICH SECRET delivers a credential, as
          `<VARIABLE> = "<secret name>"`. Everything unlisted comes from `secret`.

          This is not a convenience. A workload that reads one credential from a Secret another
          team owns and the rest from its own is a real arrangement, and a vocabulary that could
          only name one Secret would force the whole set into it -- which is how a Secret grows
          keys nobody meant to put there.
        '';
      };
    };

    requires = lib.mkOption {
      default = { };
      example = lib.literalExpression ''{ index.endpoint = "http://example-index:9200"; }'';
      description = ''
        WHERE each service this workload needs can be reached, keyed by the SAME names the
        catalogue uses. The catalogue says which variable carries the endpoint; this says what the
        endpoint is. Nothing here renders those services -- they have their own lifecycles, their
        own storage and their own owners.

        Leaving one out is refused rather than rendered: a workload that starts without knowing
        where its index is fails later and further from the cause.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          endpoint = lib.mkOption {
            type = lib.types.str;
            example = "http://example-index:9200";
            description = ''
              The URL, NAMING A SERVICE. A literal address is refused: an address is one network on
              one day, and a workload holding a stale one fails silently rather than loudly.
            '';
          };
        };
      });
    };

    publicUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://example.com";
      description = ''
        The URL this workload is reached at, for software that generates links to ITSELF -- a
        confirmation mail, a share link, an OAuth redirect. Only useful when the catalogue names a
        variable to carry it, and stating it where the catalogue names none is refused rather than
        quietly dropped.

        It is not an exposure term and grants nothing: `exposure` decides who can reach the
        workload, and this only tells the workload what to call itself.
      '';
    };

    identity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "media";
      description = ''
        WHO this workload runs as, as a ROLE and never a number. The grammar resolves the role
        against the consumer's own identity registry, which is the only thing that knows what uid
        a role means on a given fleet -- a number typed here would be a second authority on it, and
        the two would drift.

        Null means the image's own user, which is the honest default: a workload nobody has decided
        an identity for has not acquired one by omission.
      '';
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra plain environment, merged OVER whatever the catalogue supplies. Plain is the
        operative word: a credential belongs in a Secret and arrives through `credentials`.

        This is where capacity goes — heap sizes, cache sizes, worker counts. The catalogue
        supplies what the software needs in order to be CORRECT and never what it needs in order to
        be the right size, because only the consumer knows the hardware.
      '';
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra entrypoint arguments, appended to whatever the catalogue supplies.";
    };
  };

  optionsForRoot = spec:
    let
      all = lib.attrNames commonOptions;
      enabled =
        if spec.enabledOptions != null then spec.enabledOptions
        else lib.subtractLists spec.disabledOptions all;
      unknownEnabled = lib.subtractLists all enabled;
      unknownDisabled = lib.subtractLists all spec.disabledOptions;
      unknown = lib.unique (unknownEnabled ++ unknownDisabled);
      selectorCollidesWithCommon = spec.entry == null && lib.elem spec.selector all;
      extraDefinesSelector =
        spec.entry == null && builtins.hasAttr spec.selector spec.extraOptions;
      selectorOption = lib.optionalAttrs (spec.entry == null) {
        ${spec.selector} = lib.mkOption ({
          type = lib.types.enum (lib.attrNames spec.catalogue);
          description =
            "Which entry from this root's catalogue the workload runs. Available: "
            + lib.concatStringsSep ", " (lib.attrNames spec.catalogue) + ".";
        } // lib.optionalAttrs (spec.selectorDefault != null) {
          default = spec.selectorDefault;
        });
      };
    in
    if spec.enabledOptions != null && spec.disabledOptions != [ ] then
      throw "mkConsumerModule: root `${spec.rootName}` may set `enabledOptions` or `disabledOptions`, never both"
    else if selectorCollidesWithCommon then
      throw ("mkConsumerModule: selector `" + spec.selector + "` for root `${spec.rootName}` "
        + "collides with a common workload option; a selector must have its own distinct name")
    else if extraDefinesSelector then
      throw ("mkConsumerModule: extraOptions for root `${spec.rootName}` define its selector `"
        + spec.selector + "`; selector options are owned by the catalogue root")
    else if unknown != [ ] then
      throw ("mkConsumerModule: root `${spec.rootName}` names unknown common options: "
        + lib.concatStringsSep ", " unknown)
    else
      # `enable` is structural and never suppressible. A root may remove a cluster term entirely
      # (CI runners have no `slot` or `exposure`; category-routed apps have no `namespace`) by
      # leaving it out of `enabledOptions`, which makes writing it an UNKNOWN OPTION rather than a
      # value a later assertion merely dislikes.
      lib.getAttrs (lib.unique ([ "enable" ] ++ enabled)) commonOptions
      // selectorOption
      // spec.extraOptions;

  rootOption = rootName: spec:
    lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule (submodule@{ name, ... }:
        let
          declaration = submodule.config;
          w = workloadDefaults // declaration;
          entry = entryOf spec declaration;
          selected = selectionOf spec declaration;
          base = {
            inherit name entry selected platform spec;
            consumer = cfg;
            moduleConfig = config;
            inherit w declaration;
            root = rootName;
          };
          context = base // { kind = spec.kind base; };
          defaults = spec.defaults context;
          forbiddenDefaults = [ "enable" ] ++ lib.optional (spec.entry == null) spec.selector;
          checkedDefaults =
            if !(lib.isAttrs defaults) then
              throw "mkConsumerModule: defaults for root `${rootName}` must return an attribute set"
            else
              let collisions = lib.intersectLists forbiddenDefaults (lib.attrNames defaults); in
              if collisions != [ ] then
                throw ("mkConsumerModule: defaults for root `${rootName}` may not define "
                  + lib.concatMapStringsSep ", " (n: "`${n}`") collisions
                  + "; use `enableByDefault` or `selectorDefault` for those fixed-point inputs")
              else defaults;
        in {
          options = optionsForRoot spec;
          config = lib.mkMerge [
            { enable = lib.mkDefault (spec.enableByDefault context); }
            (lib.mapAttrs (_: value: lib.mkDefault value) checkedDefaults)
          ];
        }));
      default = { };
      description = if spec.description != null then spec.description else ''
        Workloads from `${rootName}`, keyed by a name of your choosing. The key is the workload's
        identity; its selected catalogue entry decides whether it renders through the app grammar,
        as opaque manifests, or as a reference that deliberately renders nothing.
      '';
    };

  reservedRootNames = [ platformOption "clusterSlots" "renderedByGrammar" "renderedDirectly" "notRendered" ];
  collidingRootNames = lib.intersectLists reservedRootNames (lib.attrNames rootSpecs);
  builtInPlatformOptionNames =
    [ "project" "origin" ] ++ lib.optional (anyRootUsesCommonOption "namespace") "namespace";
  extraPlatformCollisions = lib.intersectLists
    builtInPlatformOptionNames
    (lib.attrNames extraPlatformOptions);
  checkedExtraPlatformOptions =
    if extraPlatformCollisions != [ ] then
      throw ("mkConsumerModule: extraPlatformOptions collide with built-in options: "
        + lib.concatStringsSep ", " extraPlatformCollisions)
    else extraPlatformOptions;
  extraNamespaceCollisions = lib.intersectLists
    (reservedRootNames ++ lib.attrNames rootSpecs)
    (lib.attrNames extraNamespaceOptions);
  checkedExtraNamespaceOptions =
    if extraNamespaceCollisions != [ ] then
      throw ("mkConsumerModule: extraNamespaceOptions collide with built-ins or roots: "
        + lib.concatStringsSep ", " extraNamespaceCollisions)
    else extraNamespaceOptions;
  rootOptionDeclarations =
    if collidingRootNames != [ ] then
      throw ("mkConsumerModule: roots use reserved names: " + lib.concatStringsSep ", " collidingRootNames)
    else lib.mapAttrs rootOption rootSpecs;
in
{
  options = lib.setAttrByPath checkedOptionPath ({
    ${platformOption} = (lib.optionalAttrs (anyRootUsesCommonOption "namespace") {
      namespace = lib.mkOption {
        type = lib.types.str;
        description = ''
          The namespace workloads land in unless one says otherwise.

          DEFAULTED NOWHERE, deliberately. A default here could only be this repository's own name,
          which is a guess at a cluster's layout dressed up as a value -- and a workload that lands
          in a namespace nobody chose is one somebody has to go looking for. A cluster fact: this
          repository knows what its software IS and never where anybody puts it.
        '';
      };
    }) // {
      project = lib.mkOption {
        type = lib.types.str;
        description = ''
          The delivery project workloads belong to unless one says otherwise. Named by the
          consumer's tenancy layer, which this repository cannot see -- so, like `namespace`, it is
          defaulted nowhere rather than guessed.
        '';
      };

      origin = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          WHICH DECLARING MODULE SET these workloads come from, as the band model underneath reads
          it — in practice the repository whose modules declare them. Setting it is what turns a
          slot from a number checked only for collisions into one checked against the RANGE its
          origin is allowed to draw from.

          Null by default because the band model is the consumer's: a repository that named its
          own band would be asserting a fleet's addressing policy from outside the fleet.
        '';
      };
    } // checkedExtraPlatformOptions;

    clusterSlots = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.unsigned;
      readOnly = true;
      default = lib.listToAttrs
        (map
          (x: lib.nameValuePair x.name x.w.slot)
          (lib.filter (x: (x.w.slot or null) != null) allWorkloads));
      defaultText = lib.literalExpression "every declared workload that claims a slot";
      description = ''
        workload -> the position it claims, for every workload here that claims one. Nothing is
        rendered from it: what an address looks like is the consumer's business, and this is what
        the consumer reads to build one.
      '';
    };

    renderedByGrammar = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.sort (a: b: a < b) (map (x: x.name) workloads);
      defaultText = lib.literalExpression "every enabled entry dispatched to `app`";
      description = "Declarations rendered in full through the nixk3s app grammar.";
    };

    renderedDirectly = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.sort (a: b: a < b)
        (map (x: x.name) (lib.filter (x: x.spec.manifestsOf x != [ ]) manifestWorkloads));
      defaultText = lib.literalExpression "every enabled `manifest` entry carrying at least one object";
      description = "Declarations delivered as opaque manifests rather than through the app grammar.";
    };

    notRendered = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.sort (a: b: a < b) (map (x: x.name) referenceWorkloads);
      defaultText = lib.literalExpression "every enabled entry dispatched to `reference`";
      description = "Declarations that deliberately render no object, but remain available to interlocks.";
    };
  } // rootOptionDeclarations // checkedExtraNamespaceOptions);

  config = lib.mkMerge [
    {
      nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) workloads);

      applications = lib.listToAttrs (map
        (x: lib.nameValuePair (renderNameOf x) (mkManifestApplication x))
        (lib.filter (x: x.spec.manifestsOf x != [ ]) manifestWorkloads));

      # `nixidy.assertions`, not the module system's own `assertions`: this renders into a nixidy
      # environment, which has no NixOS-style assertion plumbing and would refuse the bare name.
      nixidy.assertions =
        stateAssertions
        ++ probeAssertions
        ++ credentialAssertions
        ++ imageAssertions
        ++ idleAssertions
        ++ replicaAssertions
        ++ containerAssertions
        ++ volumeNameAssertions
        ++ authAssertions
        ++ nestingAssertions
        ++ identityAssertions
        ++ requiresAssertions
        ++ publicUrlAssertions
        ++ anchorAssertions
        ++ slotAssertions
        ++ addressingAvailabilityAssertions
        ++ dispatchAssertions
        ++ declarationNameAssertions
        ++ renderNameAssertions
        ++ applicationKeyAssertions
        ++ rootAssertions
        ++ extraAssertions allWorkloads;

      nixidy.warnings =
        builtinWarnings
        ++ nestingWarnings
        ++ idleWarnings
        ++ authWarnings
        ++ dispatchWarnings
        ++ rootWarnings
        ++ extraWarnings allWorkloads;
    }
    # Addressing counts occupancy from grammar apps automatically. A manifest or reference lives
    # below that grammar and would otherwise advertise its real slot as free. Emit reservations
    # only when the consumer has opted into the addressing vocabulary by naming an origin -- the
    # same condition under which grammar apps receive `origin` and `slot` above.
    (lib.optionalAttrs addressingIsDefined {
      nixk3s.addressing.reservations = lib.mkIf
        (platform.origin != null && nonGrammarSlotWorkloads != [ ])
        (lib.listToAttrs (map
          (x: lib.nameValuePair x.name {
            slot = x.w.slot;
            origin = platform.origin;
            note = "${x.root}.${x.name}, delivered as ${x.kind} by ${namespace}";
          })
          nonGrammarSlotWorkloads));
    })
    (extraConfig allWorkloads)
  ];
}
