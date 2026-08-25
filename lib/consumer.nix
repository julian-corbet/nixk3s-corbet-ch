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

  mountPathOf = s: if lib.isString s then s else s.mountPath;
  entryReadOnly = s: if lib.isString s then null else (s.readOnly or null);

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
, catalogue
, root ? "applications"
, selector ? "app"
, platformOption ? "clusterPlatform"
, extraOptions ? { }
, extend ? (_entry: _w: app: app)
, extraAssertions ? (_workloads: [ ])
, extraWarnings ? (_workloads: [ ])
}:

{ config, lib, ... }:

let
  cfg = config.${namespace};
  platform = cfg.${platformOption};

  declared = lib.filterAttrs (_: w: w.enable) cfg.${root};
  workloads = lib.mapAttrsToList
    (name: w: { inherit name w; entry = catalogue.${w.${selector}}; })
    declared;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks
  # like. The catalogue never carries either: a version is a deployment's choice and a digest is
  # one deployment's proof of what it is running.
  imageOf = entry: w: if w.image != null then w.image else "${entry.image}:${w.version}";

  portsOf = entry: lib.mapAttrs (_: normalisePort) entry.ports;

  # The split in one function: WHERE inside the container comes from the catalogue, WHAT BACKS IT
  # comes from the declaration, and neither side can supply the other's half.
  # The rendered volume's NAME is the catalogue's name for the directory unless the declaration
  # says the live object calls it something else -- which only an adoption ever needs.
  volumeNameOf = w: key: if w.state.${key}.volumeName != null then w.state.${key}.volumeName else key;

  # KEYS BOTH SIDES KNOW ABOUT. The guard that catches a directory only one side has is a state
  # assertion; every use of the catalogue that indexes it BY A DECLARATION'S KEY must walk the
  # intersection instead, or it throws a missing-attribute error while the assertion written to
  # explain the mistake is still being collected -- and the author gets a crash where a sentence
  # was waiting for them.
  sharedStateKeys = entry: w:
    lib.filter (k: (entry.state or { }) ? ${k}) (lib.attrNames w.state);

  stateOf = entry: w:
    lib.mapAttrs'
      (key: backing:
        let ro = entryReadOnly entry.state.${key}; in
        lib.nameValuePair (volumeNameOf w key) {
          mountPath = mountPathOf entry.state.${key};
          inherit (backing) claim hostPath hostPathType configMap secret emptyDir ownership;
          readOnly = if ro != null then ro else backing.readOnly;
        })
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
      // lib.optionalAttrs ((h.rootFilesystem or null) != null) {
        readOnlyRootFilesystem = h.rootFilesystem == "read-only";
      }
      // lib.optionalAttrs ((h.runAsNonRoot or null) != null) { inherit (h) runAsNonRoot; }
    );

  # Four named scalars in, two maps out, nulls dropped. A field nobody set renders no key, which
  # is what lets a declaration carry exactly the subset its live object already has.
  resourcesOf = w: {
    requests = dropNulls { cpu = w.resources.cpuRequest; memory = w.resources.memoryRequest; };
    limits = dropNulls { cpu = w.resources.cpuLimit; memory = w.resources.memoryLimit; };
  };

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
      inherit (w) slot;
    };

  mkApp = x:
    let inherit (x) entry w; in
    extend entry w (
      {
        inherit (w) namespace createNamespace project exposure scaling adopt;
        image = imageOf entry w;
        ports = portsOf entry;
        state = stateOf entry w;
        secrets = secretsOf entry w;
        # ORDER IS THE POINT. The catalogue's own environment first, then the endpoints of the
        # services this one needs, then its own public URL, then whatever the declaration adds --
        # so a consumer can override any of it and nothing can override the consumer.
        env = (entry.env or { }) // requiresEnvOf entry w // selfEnvOf entry w // w.env;
        args = (entry.args or [ ]) ++ w.args;
        probes = probesOf entry w;
        security = securityOf entry w;
        resources = resourcesOf w;
      }
      // lib.optionalAttrs (w.wake != null) { inherit (w) wake; }
      // identityOf entry w
      // addressingOf w
    );

  # ── Assertions ───────────────────────────────────────────────────────────────────────────────
  #
  # Every one of these refuses a declaration that would otherwise render something the author did
  # not mean. They are phrased as questions about the SPLIT: a half supplied without its other
  # half, or a half supplied for something that has none.

  stateAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames (entry.state or { });
          message =
            "${namespace}: workload `${name}` must back every directory it writes, and backs "
            + (if w.state == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames w.state))
            + ". It writes: "
            + (if (entry.state or { }) == { } then "nothing"
            else lib.concatStringsSep ", "
              (lib.mapAttrsToList (k: p: "`${k}` at ${mountPathOf p}") entry.state))
            + ".";
        }
        {
          assertion = lib.all
            (backing:
              lib.length (lib.filter (b: b) [
                (backing.claim != null)
                (backing.hostPath != null)
                (backing.configMap != null)
                (backing.secret != null)
                backing.emptyDir
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
            let names = map (k: volumeNameOf w k) (lib.attrNames w.state); in
            lib.length (lib.unique names) == lib.length names;
          message =
            "${namespace}: workload `${name}` renames two directories onto one volume name. One of "
            + "them would simply not be mounted, and which one is an accident of attribute order.";
        }
        {
          # The catalogue's half of an ownership decision: a directory it says GROWS must never be
          # chowned recursively on every pod start, because that cost scales with the tree and the
          # tree is the thing that keeps getting bigger.
          assertion = lib.all
            (key: !((entry.state.${key}.grows or false) && w.state.${key}.ownership == "kubelet"))
            (sharedStateKeys entry w);
          message =
            "${namespace}: workload `${name}` asks the kubelet to own a directory the catalogue says "
            + "GROWS. That means chowning it recursively on every single pod start, over a tree "
            + "whose whole purpose is to keep getting bigger -- and on a path somebody curates "
            + "outside the cluster it destroys ownership that was set there deliberately.";
        }
      ])
    workloads;

  # A budget is an override of something, so there has to be something. Budgeting a probe the
  # software does not warrant is the same class of mistake as backing a directory it does not
  # write: the attribute would be silently dropped on the way to the manifest, and the declaration
  # would go on saying something the cluster never heard.
  probeAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        shapes = probeShapesOf entry;
        stray = lib.subtractLists (lib.attrNames shapes) (lib.attrNames w.probes);
      in
      [{
        assertion = stray == [ ];
        message =
          "${namespace}: workload `${name}` budgets "
          + lib.concatMapStringsSep ", " (k: "`${k}`") stray
          + ", which `${w.${selector}}` does not warrant. It warrants: "
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
        inherit (x) name w entry;
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
              "${namespace}: workload `${name}` names a Secret, and `${w.${selector}}` reads no "
              + "credential from its environment. A reference nothing consumes is a typo, not a "
              + "declaration.";
        }
        {
          assertion = stray == [ ];
          message =
            "${namespace}: workload `${name}` maps a key for "
            + lib.concatMapStringsSep ", " (v: "`${v}`") stray
            + ", which `${w.${selector}}` does not read. A key mapping renames the KEY inside the "
            + "Secret for a variable the software already looks in; it cannot invent the variable.";
        }
      ])
    workloads;

  # IDLING IS A CORRECTNESS QUESTION, not a preference, which is why this refuses rather than
  # warns. A catalogue says a workload is unsafe to idle when it has work that happens while nobody
  # is looking -- a timer, a queue, a directory watch. Scaling that to zero does not make it slow,
  # it makes it silently not happen.
  idleAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [{
        assertion = w.scaling != "scale-to-zero" || (entry.idleSafe or true);
        message =
          "${namespace}: workload `${name}` is declared scale-to-zero, and `${w.${selector}}` is "
          + "catalogued as unsafe to idle -- it has work that happens while nobody is looking. At "
          + "zero replicas that work does not happen late, it does not happen. Leave it `always` "
          + "and idle whatever fronts it instead.";
      }])
    workloads;

  # Both directions again. A dependency the catalogue names and the declaration leaves out is a
  # workload started without knowing where something is; one the declaration names and the
  # catalogue does not know about is a URL nothing will ever read.
  requiresAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
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
            + ", which `${w.${selector}}` does not read. An endpoint nothing consumes is a typo, "
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
            + " that does not speak the protocol `${w.${selector}}` expects there. The catalogue "
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
        pairs = lib.concatMap
          (outer: lib.concatMap
            (inner:
              lib.optional
                (outer != inner
                  && lib.hasPrefix "${pathOf outer}/" (pathOf inner)
                  && volumeNameOf w inner < volumeNameOf w outer)
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
    workloads;

  # The same collision, caused by a rename rather than by the catalogue. It warns because a rename
  # records what a live object is ALREADY called: refusing would make an existing cluster
  # undeclarable, which is not the same service as catching a mistake.
  nestingWarnings = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        keys = sharedStateKeys entry w;
        pathOf = k: mountPathOf entry.state.${k};
        renamed = lib.concatMap
          (outer: lib.concatMap
            (inner:
              lib.optional
                (outer != inner
                  && lib.hasPrefix "${pathOf outer}/" (pathOf inner)
                  && !(inner < outer)
                  && volumeNameOf w inner < volumeNameOf w outer)
                { inherit outer inner; })
            keys)
          keys;
      in
      map
        (c: {
          when = true;
          message =
            "${namespace}: workload `${name}` renames `${c.inner}` to "
            + "`${volumeNameOf w c.inner}`, which now sorts before `${volumeNameOf w c.outer}` -- "
            + "the volume covering it at ${pathOf c.outer}. Mounts render in that order, so the "
            + "outer one is laid over the inner and its data stops being visible. The names are "
            + "presumably what the live objects already carry, which is why this is not refused.";
        })
        renamed)
    workloads;

  # WHO IT RUNS AS, refused in both directions. An image that can only start as uid 0 and a
  # declaration that names a role are each individually sensible and together are a contradiction:
  # the role would be silently ignored, which is the worst outcome -- somebody believes they
  # dropped privileges. And an image that reads its ids from the environment with no role to read
  # gets no ids at all, so it runs as whatever the image's own USER is while the declaration looks
  # like it decided something.
  identityAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
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
            + "`${w.${selector}}` can only START as uid 0 with no variable to read a role from. The "
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

  # A public URL nothing reads is not harmless -- it is somebody believing they configured a link
  # base. The catalogue decides whether this software has one to configure.
  publicUrlAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [{
        assertion = w.publicUrl == null || (entry.selfUrlEnv or null) != null;
        message =
          "${namespace}: workload `${name}` is given a public URL, and `${w.${selector}}` reads no "
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
      anchors = lib.filter (x: x.w.createNamespace) workloads;
      byNs = lib.groupBy (x: x.w.namespace) anchors;
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
      claimed = lib.filter (x: x.w.slot != null) workloads;
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

  # A warning is `{ when; message; }` — the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  builtinWarnings = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          when = w.scaling == "scale-to-zero" && w.wake == null;
          message =
            "${namespace}: workload `${name}` is declared scale-to-zero with no wake front, so "
            + "nothing brings it back. At zero replicas that is not an idle workload, it is an "
            + "unreachable one.";
        }
        {
          when = w.image != null;
          message =
            "${namespace}: workload `${name}` carries a whole image reference, so the `version` "
            + "beside it now chooses nothing -- the reference decides what runs. Keep them agreeing "
            + "anyway: the version is what a reader looks at, and a stale one is a reader misled by "
            + "a declaration that is technically correct.";
        }
        {
          when = w.slot != null && platform.origin == null;
          message =
            "${namespace}: workload `${name}` claims slot ${toString w.slot}, and "
            + "`${namespace}.${platformOption}.origin` is unset — so the number is checked for "
            + "collisions inside this repository and by nothing for which RANGE it may come from.";
        }
        {
          when = !w.harden && ((entry.hardening or null) != null);
          message =
            "${namespace}: workload `${name}` renders no securityContext, and `${w.${selector}}` is "
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

  commonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    ${selector} = lib.mkOption {
      type = lib.types.enum (lib.attrNames catalogue);
      description =
        "Which entry from the catalogue this workload runs. Available: "
        + lib.concatStringsSep ", " (lib.attrNames catalogue) + ".";
    };

    version = lib.mkOption {
      type = lib.types.str;
      description = ''
        Which version this workload runs, used as the image tag. REQUIRED and defaulted nowhere:
        a catalogue that guessed a version would be guessing what is running in somebody else's
        cluster, and a default here would be that guess wearing a value's clothes.
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

    namespace = lib.mkOption {
      type = lib.types.str;
      default = platform.namespace;
      defaultText = lib.literalExpression "config.${namespace}.${platformOption}.namespace";
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
      defaultText = lib.literalExpression "config.${namespace}.${platformOption}.project";
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

    resources = {
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
          what anybody wants — an app that briefly needs more is made slower rather than stopped.
        '';
      };
      memoryLimit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "256Mi";
        description = ''
          Memory ceiling, which IS a kill threshold — usually what a leaky application wants, and
          the reason this one is worth setting where the CPU one is not.
        '';
      };
    };

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
in
{
  options.${namespace} = {
    ${platformOption} = {
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
    };

    ${root} = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = commonOptions // extraOptions;
      });
      default = { };
      description = ''
        Workloads from this repository's catalogue that run in the cluster, keyed by a name of your
        choosing. The key is the workload's name; `${selector}` says which catalogue entry it runs,
        so the same software can run twice under two names.
      '';
    };

    clusterSlots = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.unsigned;
      readOnly = true;
      default = lib.listToAttrs
        (map (x: lib.nameValuePair x.name x.w.slot) (lib.filter (x: x.w.slot != null) workloads));
      defaultText = lib.literalExpression "every declared workload that claims a slot";
      description = ''
        workload -> the position it claims, for every workload here that claims one. Nothing is
        rendered from it: what an address looks like is the consumer's business, and this is what
        the consumer reads to build one.
      '';
    };
  };

  config = {
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) workloads);

    # `nixidy.assertions`, not the module system's own `assertions`: this renders into a nixidy
    # environment, which has no NixOS-style assertion plumbing and would refuse the bare name.
    nixidy.assertions =
      stateAssertions
      ++ probeAssertions
      ++ credentialAssertions
      ++ idleAssertions
      ++ nestingAssertions
      ++ identityAssertions
      ++ requiresAssertions
      ++ publicUrlAssertions
      ++ anchorAssertions
      ++ slotAssertions
      ++ extraAssertions workloads;

    nixidy.warnings = builtinWarnings ++ nestingWarnings ++ extraWarnings workloads;
  };
}
