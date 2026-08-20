# nixk3s.cockpit — the platform's own faces: declare which of them run in the cluster, and render
# them through the app grammar.
#
# ── WHY A CATALOGUE HERE DOES NOT BREAK THIS REPOSITORY'S CHARTER ──────────────────────────────
#
# Everything else here is MECHANISM. The app grammar renders whatever anybody declares and
# deliberately knows nothing about what kind of apps they have: a taxonomy of applications belongs
# to whoever ships the applications, and a repository that grows one has started choosing which
# software its users are allowed to run.
#
# NOTHING IN THIS MODULE IS AN APP YOU HAVE. A cockpit face is the platform looking at itself — the
# thing you open to find out whether the cluster that runs your apps is working. Delete every
# workload on the cluster and this catalogue is unchanged and still has a job: there is still a
# cluster, and it still has to be watchable. A catalogue of "apps you have" is empty on that same
# cluster, which is exactly the difference and exactly the test:
#
#   A face belongs here only if it would still be worth running on a cluster with no apps in it.
#
# The GitOps controller, the console you look at objects through, and the portal that is the front
# door to those surfaces pass it. A wiki, a media server, a dashboard somebody likes do not,
# however often anyone opens them: they are things the platform CARRIES, and carrying is the
# grammar's business, which stays incurious about the cargo.
#
# ── STRUCTURALLY SEPARATE, NOT SEPARATE BY CONVENTION ──────────────────────────────────────────
#
# The dependency runs ONE WAY and the code says so. The grammar does not import this module and
# cannot see it; this module imports the grammar, because a translator with nothing to translate
# into is not a module. `nixidyModules.default` carries the grammar and its interlocks and NOT the
# cockpit, so a consumer who imports everything still acquires no opinion about which dashboards
# exist — taking the cockpit is its own deliberate line. That claim is checked rather than
# asserted: `checks.tenancy-renders` composes the grammar without this module, and would fail the
# day the grammar started needing it.
#
# ── A TRANSLATOR, NOT A RENDERER ───────────────────────────────────────────────────────────────
#
# This module DEFINES INTO `nixk3s.apps` and renders no Kubernetes object of its own. Everything
# expressible in the grammar's terms is expressed in them — the image, the ports, the exposure
# class, whether it may sleep, which directories it writes and what backs them. What this adds is
# the one thing the grammar cannot know: what a particular face IS. Which of them keeps a database
# and therefore cannot roll; which must never be started against an empty directory; which probes
# it needs, what answers them, and which probe it must never be given because the one time it
# answers late is the migration that must not be interrupted.
#
# ── THE KNOWLEDGE/VALUE SPLIT, ENFORCED RATHER THAN TRUSTED ────────────────────────────────────
#
# `lib/cockpit.nix` holds what is true of the software anywhere. A declaration holds what is true
# of one cluster. Neither may supply the other's half: the catalogue says WHERE inside the
# container a directory lives and only a declaration can say WHAT BACKS IT, the catalogue says
# WHICH probes exist and what page answers them and only a declaration can say HOW LONG each may
# take, the catalogue names the variables that must come from a Secret and only a declaration can
# name the Secret, and a declaration cannot reach the variables that describe the container's own
# insides at all.
#
# ONE REFUSAL IS WAIVABLE, AND ONLY IN ONE DIRECTION. A face the catalogue says must never start
# against an empty directory may be backed by one that creates it — but only by a declaration that
# is ADOPTING an existing object, that says in a sentence why the safe backing cannot be written
# yet, and only where the refusal would otherwise have fired. It then warns at every render and
# appears in `nixk3s.cockpit.emptyStartAccepted`, because the alternative is not a safer cluster:
# it is the same live object declared outside this module, where nothing counts it at all.
{ config, lib, ... }:

let
  cfg = config.nixk3s.cockpit;
  catalogue = (import ../../lib/cockpit.nix { }).faces;

  declared = lib.filterAttrs (_: s: s.enable) cfg.surfaces;
  surfaces = lib.mapAttrsToList (name: s: { inherit name s; face = catalogue.${s.face}; }) declared;

  # THE BAND MODEL IS A SIBLING, not a dependency. Its terms (`origin`, `slot`) are options it adds
  # to the grammar's apps, so defining them into a render that does not compose it is an eval error
  # about an option that does not exist. Detected rather than assumed, so a surface that claims a
  # position without it gets a sentence naming the missing module instead.
  addressingComposed = (config.nixk3s.addressing or null) != null;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks like.
  # The catalogue carries neither: a version is a deployment's choice and a digest is one
  # deployment's proof of what it is running.
  imageOf = face: s: if s.image != null then s.image else "${face.image}:${s.version}";

  portsOf = face: lib.mapAttrs (_: number: { inherit number; }) face.ports;

  # The split in one function: WHERE inside the container comes from the catalogue, WHAT BACKS IT
  # comes from the declaration, and neither side can supply the other's half. `hostPathType`
  # travels only with a node path — the grammar refuses it beside any other backing, because it
  # describes a directory on a node and nothing else.
  stateOf = face: s:
    lib.mapAttrs
      (key: backing:
        { mountPath = face.state.${key}.path; inherit (backing) claim hostPath; }
        // lib.optionalAttrs (backing.hostPath != null) { inherit (backing) hostPathType; })
      s.state;

  # THE SHAPE FROM THE CATALOGUE, THE BUDGET FROM THE DECLARATION, aimed at the port the catalogue
  # records. Which probes exist and what answers them is true of the software; how long each may
  # take is a stopwatch held against one cluster's disks, so neither side can supply the other's
  # half. A probe the catalogue leaves out is not rendered here at all -- and one it REFUSES
  # (`probesRefused`) cannot be budgeted into existence, which is a guard rather than a filter.
  probesOf = face: s:
    lib.mapAttrs
      (name: shape:
        let budget = s.probes.${name} or null; in
        { port = face.primaryPort; }
        // shape
        // lib.optionalAttrs (budget != null) {
          inherit (budget) initialDelaySeconds periodSeconds failureThreshold timeoutSeconds;
        })
      face.probes;

  # The uid the image drops to, in the spelling the image reads it in. The names are knowledge; the
  # numbers are the consumer's, and they only exist here as two integers on their way into an
  # environment.
  identityEnvOf = face: s:
    lib.optionalAttrs (face.dropsPrivilegesVia != null && s.posixIdentity != null) {
      ${face.dropsPrivilegesVia.user} = toString s.posixIdentity.uid;
      ${face.dropsPrivilegesVia.group} = toString s.posixIdentity.gid;
    };

  # Secrets named, never carried, and consumed by named key: a `secretKeyRef` reaches the container
  # without the value passing through Nix or the rendered tree.
  secretsOf = s: lib.mapAttrs (_: sec: { inherit (sec) env; }) s.secrets;

  # Which variables a declaration is not allowed to set, and why each is on the list: the ones that
  # describe the container's own insides, and the ones that carry the identity the declaration
  # states as two numbers instead.
  reservedEnvOf = face:
    lib.attrNames face.env
    ++ lib.optionals (face.dropsPrivilegesVia != null)
      [ face.dropsPrivilegesVia.user face.dropsPrivilegesVia.group ];

  secretEnvNamesOf = s: lib.concatMap (sec: lib.attrNames sec.env) (lib.attrValues s.secrets);

  mkApp = x:
    let inherit (x) face s; in
    {
      inherit (s) namespace createNamespace project exposure scaling adopt;
      inherit (face) identity security;
      image = imageOf face s;
      ports = portsOf face;
      state = stateOf face s;
      secrets = secretsOf s;
      env = face.env // identityEnvOf face s // s.env;
      probes = probesOf face s;
    }
    // lib.optionalAttrs (s.wake != null) { inherit (s) wake; }
    // lib.optionalAttrs (s.slot != null && addressingComposed) {
      inherit (cfg) origin;
      inherit (s) slot;
    };

  ## ---------------------------------------------------------------------
  ## Assertions
  ## ---------------------------------------------------------------------

  stateAssertions = lib.concatMap
    (x:
      let inherit (x) name s face; in
      [
        {
          assertion = lib.attrNames s.state == lib.attrNames face.state;
          message =
            "nixk3s.cockpit: surface `${name}` must back every directory it writes, and backs "
            + (if s.state == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames s.state))
            + ". It writes: "
            + (if face.state == { } then "nothing"
            else lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "`${k}` at ${v.path}") face.state))
            + ".";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues s.state);
          message =
            "nixk3s.cockpit: surface `${name}` must back each directory with EITHER an existing claim "
            + "OR a node path, never both and never neither. A directory with no backing is the pod's "
            + "own filesystem, which is discarded on the restart this face's own database guarantees.";
        }
      ]
      # THE MUST-EXIST GUARD, quoting the catalogue's own reason back rather than restating it. A
      # backing that creates the directory when it is missing does not turn a lost volume into a
      # failed start; it turns it into a healthy pod with nothing in it.
      ++ lib.mapAttrsToList
        (key: backing: {
          assertion =
            !(face.state ? ${key})
            || !(face.state.${key}.mustExist or false)
            || backing.hostPath == null
            || backing.hostPathType == "Directory"
            || backing.emptyStartAccepted != null;
          message =
            "nixk3s.cockpit: surface `${name}` backs `${key}` with a node path that is CREATED when "
            + "missing (`hostPathType = \"${backing.hostPathType}\"`), and the catalogue says that "
            + "directory must already hold data: ${face.state.${key}.mustExistReason or ""}. Back it "
            + "with `\"Directory\"`, which refuses to start the pod instead -- or, if the LIVE object "
            + "already carries the creating backing and moving it is a rollout this change is not "
            + "allowed to make, say why in `emptyStartAccepted` and the exception becomes a warning "
            + "and a countable entry instead of a paragraph in a commit message.";
        })
        s.state

      # AND THE TWO GUARDS THAT KEEP THAT WAIVER FROM BECOMING A SETTING. The first reads the value
      # as its own first term, on every path, so the option is type-checked for a declaration that
      # never uses it; the second is the only thing that stops "accepted" from being the shortest
      # way past a refusal somebody found inconvenient.
      ++ lib.mapAttrsToList
        (key: backing: {
          assertion =
            backing.emptyStartAccepted == null
            || ((face.state.${key}.mustExist or false)
            && backing.hostPath != null
            && backing.hostPathType == "DirectoryOrCreate");
          message =
            "nixk3s.cockpit: surface `${name}` accepts an empty start for `${key}` and nothing here "
            + "refuses one -- either the catalogue does not say that directory must already hold "
            + "data, or the backing already refuses to create it. An acknowledgement of a risk "
            + "nobody is taking outlives the risk and then reads as permission: delete it.";
        })
        s.state
      ++ lib.mapAttrsToList
        (key: backing: {
          assertion = backing.emptyStartAccepted == null || s.adopt;
          message =
            "nixk3s.cockpit: surface `${name}` accepts an empty start for `${key}` and is not "
            + "adopting anything (`adopt = false`). The one thing that acceptance can honestly mean "
            + "is that a LIVE object already carries the creating backing and changing it is a "
            + "manifest change -- which on a face whose database forces `Recreate` is a "
            + "stop-then-start, not a rolling update. On an object nobody has created yet there is "
            + "nothing to accept: write `\"Directory\"` and the pod refuses to start against "
            + "nothing.";
        })
        s.state)
    surfaces;

  # ── PROBES: the catalogue names them, the declaration budgets them ────────────────────────────
  probeAssertions = lib.concatMap
    (x:
      let
        inherit (x) name s face;
        refused = lib.attrNames (face.probesRefused or { });
        needed = lib.attrNames face.probes;
        budgeted = lib.attrNames (removeAttrs s.probes refused);
      in
      [
        {
          assertion = budgeted == needed;
          message =
            "nixk3s.cockpit: surface `${name}` must budget every probe the catalogue says this face "
            + "needs, and budgets "
            + (if budgeted == [ ] then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") budgeted)
            + ". It needs: "
            + (if needed == [ ] then "none"
            else lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "`${k}` on ${v.path}") face.probes))
            + ". The catalogue knows WHICH probes there are and WHAT answers them; how long each may "
            + "take is a measurement of one cluster's disks, so the numbers are this declaration's "
            + "and are defaulted nowhere.";
        }
      ]
      ++ map
        (probe: {
          assertion = !(s.probes ? ${probe});
          message =
            "nixk3s.cockpit: surface `${name}` budgets a `${probe}` probe and the catalogue says "
            + "this face must not have one: ${face.probesRefused.${probe}}.";
        })
        refused)
    surfaces;

  envAssertions = lib.concatMap
    (x:
      let
        inherit (x) name s face;
        reserved = reservedEnvOf face;
        taken = lib.filter (k: s.env ? ${k}) reserved;
        fromSecret = secretEnvNamesOf s;
        missingSecretEnv = lib.filter (k: !(lib.elem k fromSecret)) face.secretEnv;
        secretAsValue = lib.filter (k: s.env ? ${k}) face.secretEnv;
      in
      [
        {
          assertion = taken == [ ];
          message =
            "nixk3s.cockpit: surface `${name}` sets "
            + lib.concatMapStringsSep ", " (k: "`${k}`") taken
            + ", which the catalogue owns. Those variables describe the container's own insides -- "
            + "where its datastores live inside it, and the identity its entrypoint drops to -- so a "
            + "deployment that redefines one is pointing the software at something this pod is not.";
        }
        {
          assertion = missingSecretEnv == [ ];
          message =
            "nixk3s.cockpit: surface `${name}` must take "
            + lib.concatMapStringsSep ", " (k: "`${k}`") missingSecretEnv
            + " from a Secret, and takes it from nothing. A value that must survive every restart "
            + "unchanged cannot come from a tree that is rewritten on every render.";
        }
        {
          assertion = secretAsValue == [ ];
          message =
            "nixk3s.cockpit: surface `${name}` sets "
            + lib.concatMapStringsSep ", " (k: "`${k}`") secretAsValue
            + " as a plain value. That is a secret by reference or not at all: everything rendered "
            + "here is committed, so a value written there is a secret published.";
        }
      ])
    surfaces;

  identityAssertions = lib.concatMap
    (x:
      let inherit (x) name s face; in
      [
        {
          assertion = face.dropsPrivilegesVia == null || s.posixIdentity != null;
          message =
            "nixk3s.cockpit: surface `${name}` runs an image that starts as root and DROPS to the "
            + "identity it is handed"
            + lib.optionalString (face.dropsPrivilegesVia != null)
              " (`${face.dropsPrivilegesVia.user}`/`${face.dropsPrivilegesVia.group}`)"
            + ", and no `posixIdentity` says which one. The entrypoint chowns the backed directory "
            + "to that identity, so guessing it is guessing the ownership of somebody's storage.";
        }
        {
          assertion = face.dropsPrivilegesVia != null || s.posixIdentity == null;
          message =
            "nixk3s.cockpit: surface `${name}` states a `posixIdentity` and its image does not drop "
            + "privileges through one. Nothing would read those numbers, and an identity nothing "
            + "reads is a pod running as something else with a declaration saying otherwise.";
        }
      ])
    surfaces;

  # A namespace outlives every workload in it, so exactly one thing may own it. Two anchors is not a
  # merge, it is two Namespace objects Argo CD fights over.
  anchorAssertions =
    let
      anchors = lib.filter (x: x.s.createNamespace) surfaces;
      byNs = lib.groupBy (x: x.s.namespace) anchors;
    in
    lib.mapAttrsToList
      (ns: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixk3s.cockpit: namespace `${ns}` is anchored by ${toString (lib.length xs)} surfaces ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). Exactly one surface may create a namespace.";
      })
      byNs;

  slotAssertions =
    let
      claimed = lib.filter (x: x.s.slot != null) surfaces;
      bySlot = lib.groupBy (x: toString x.s.slot) claimed;
    in
    lib.mapAttrsToList
      (slot: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixk3s.cockpit: slot ${slot} is claimed by ${toString (lib.length xs)} surfaces ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). A slot is one identity in several address spaces at once; two surfaces on one number "
          + "is two surfaces on one address.";
      })
      bySlot
    ++ map
      (x: {
        assertion = addressingComposed;
        message =
          "nixk3s.cockpit: surface `${x.name}` claims slot ${toString x.s.slot} and the band model is "
          + "not part of this render, so `origin` and `slot` are not options any module here defines. "
          + "Compose `nixidyModules.addressing` (or `nixidyModules.default`) alongside this module, or "
          + "drop the slot: a position nothing governs is a number, not an identity.";
      })
      claimed;

  ## ---------------------------------------------------------------------
  ## Warnings — `{ when; message; }`, so the condition travels with the text
  ## and the renderer decides whether to print it.
  ## ---------------------------------------------------------------------

  # ACCEPTED, NOT SILENT. The refusal in `stateAssertions` is waived by a declaration that says
  # why, and this is what the waiver costs: a sentence at every render naming the directory, the
  # risk in the catalogue's own words, and the reason it is being taken anyway. A warning nobody
  # can turn off is the honest price of an exception only a live object can justify.
  emptyStartWarnings = x:
    let inherit (x) name s face; in
    lib.mapAttrsToList
      (key: backing: {
        when = backing.emptyStartAccepted != null;
        message =
          "nixk3s.cockpit: surface `${name}` starts against an EMPTY `${key}` rather than "
          + "refusing to: ${face.state.${key}.mustExistReason or ""}. Accepted here because: "
          + "${backing.emptyStartAccepted or ""}. That reason expires the day the object can be "
          + "rolled; `hostPathType = \"Directory\"` is the fix and this line is the reminder.";
      })
      s.state;

  warnings = lib.concatMap
    (x:
      let inherit (x) name s face; in
      emptyStartWarnings x
      ++ [
        {
          when = s.scaling == "scale-to-zero" && s.wake == null;
          message =
            "nixk3s.cockpit: surface `${name}` is declared scale-to-zero with no wake front, so "
            + "nothing brings it back. At zero replicas that is not an idle face, it is an "
            + "unreachable one -- and a cockpit you cannot open is worse than one that is merely "
            + "slow, because you reach for it exactly when something else is wrong.";
        }
        {
          when = s.exposure == "public" && face.authProviderEnv != null
          && !(s.env ? ${face.authProviderEnv});
          message =
            "nixk3s.cockpit: surface `${name}` is exposed to the internet and sets no "
            + "`${face.authProviderEnv}`, so nothing in this declaration says how it authenticates "
            + "anybody. This face is a map of the platform's own surfaces; whether an authenticating "
            + "front sits in front of it is something one deployment can see and this repository "
            + "cannot, which is why this warns rather than refuses.";
        }
      ])
    surfaces;

  ## ---------------------------------------------------------------------
  ## The declaration surface
  ## ---------------------------------------------------------------------

  surfaceOptions = { ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to render this surface. Declaring the attribute is declaring the surface, so this
          defaults to true; set false to park a declaration without rendering it.
        '';
      };

      face = lib.mkOption {
        type = lib.types.enum (lib.attrNames catalogue);
        description = ''
          WHICH FACE, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue)}.

          The enum is the boundary made unwritable rather than refused: a workload this repository
          does not catalogue is not a rejected value here, it is not a value at all.
        '';
      };

      version = lib.mkOption {
        type = lib.types.str;
        description = ''
          Which version this surface runs, used as the image tag. Required, and defaulted nowhere:
          a floating tag is not a default anybody can pick on somebody else's behalf.
        '';
      };

      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          A whole image reference, overriding the catalogue's repository and this surface's
          version. This is where a digest pin goes, and pinning by digest is what makes two syncs
          of an identical rendered tree run identical code.
        '';
      };

      namespace = lib.mkOption {
        type = lib.types.str;
        description = ''
          Namespace this surface lands in. Required and guessed nowhere: which namespaces exist is
          one cluster's shape.
        '';
      };

      createNamespace = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this surface anchors its namespace. Defaults to false, because creating a
          namespace is claiming something that outlives every workload in it — and where a tenancy
          layer already anchors it, the claim is somebody else's.
        '';
      };

      project = lib.mkOption {
        type = lib.types.str;
        default = cfg.project;
        defaultText = lib.literalExpression "config.nixk3s.cockpit.project";
        description = "Delivery project this surface's Application belongs to.";
      };

      slot = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = ''
          THE POSITION this surface holds in the fleet's ordered identity space, handed to the band
          model when that module is part of the render. Not an address — the layers underneath map
          it into however many address spaces the fleet keeps, which is why nothing here moves one.
          The VALUE is a fleet fact and belongs to the consumer.
        '';
      };

      exposure = lib.mkOption {
        type = lib.types.enum [ "internal" "nb" "public" ];
        default = "internal";
        description = ''
          Who can reach it, as a CLASS rather than an address. Defaults to the closed answer: a
          face nobody has thought about is not on the internet.
        '';
      };

      scaling = lib.mkOption {
        type = lib.types.enum [ "always" "scale-to-zero" ];
        default = "always";
        description = ''
          Whether this surface may idle to zero replicas.

          The catalogue records what is KNOWN about sleeping for a given face — how cold the start
          is, and what has and has not been established about what it does while nobody is looking.
          Whether it sleeps is a deployment's call, because the wake path is one cluster's routing
          and this repository cannot see whether that path is healthy.
        '';
      };

      wake = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
        default = null;
        description = ''
          Which front wakes it from zero. Meaningless unless `scaling = "scale-to-zero"`, and its
          absence there is warned about: nothing brings the surface back.
        '';
      };

      adopt = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Render this surface's Application with server-side apply and diff, for taking over
          objects that already exist. A face is usually the OLDEST thing in a cluster — it was
          running before anybody wrote a module for it — so this is the ordinary way one arrives
          here, and it is still a deployment's fact rather than the software's.
        '';
      };

      posixIdentity = lib.mkOption {
        default = null;
        description = ''
          The identity an image that starts as root DROPS to, as the two numbers it reads. Required
          exactly when the catalogue says the face works that way, and refused otherwise — an
          identity nothing reads is worse than none.

          The NAMES of the variables are knowledge and live in the catalogue. The NUMBERS are the
          shape of somebody's /etc/passwd and the ownership of somebody's directory, so they arrive
          from the consumer, exactly like a node path.
        '';
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            uid = lib.mkOption {
              type = lib.types.ints.unsigned;
              description = "Numeric user id the entrypoint drops to.";
            };
            gid = lib.mkOption {
              type = lib.types.ints.unsigned;
              description = "Numeric group id.";
            };
          };
        });
      };

      state = lib.mkOption {
        default = { };
        description = ''
          What backs each directory the catalogue says this face writes, keyed by the SAME names.
          Backing a directory the face does not write, or leaving one it does write unbacked, is an
          eval error rather than a surprise at runtime.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            claim = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "An existing PersistentVolumeClaim, by name. Nothing here creates one.";
            };
            hostPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "A directory on the node. Pins the surface to whichever node holds it.";
            };
            hostPathType = lib.mkOption {
              type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
              default = "Directory";
              description = ''
                Whether the node path must already exist. Defaults to the refusing answer, and for a
                directory the catalogue marks as one that must already hold data, the creating answer
                is refused outright: a face that starts against an empty directory is not a failed
                start, it is a healthy pod with none of your data in it.
              '';
            };

            emptyStartAccepted = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "the live volume already carries this backing and the object may not roll yet";
              description = ''
                WHY this deployment takes the risk the catalogue refuses, in a sentence. Setting it
                turns that refusal into a warning at every render and an entry in
                `nixk3s.cockpit.emptyStartAccepted`; leaving it `null` (the default) leaves the
                refusal a refusal.

                THERE IS EXACTLY ONE HONEST REASON and the module holds the declaration to it. An
                object that ALREADY EXISTS carries the backing it was created with, and changing
                that field is a manifest change — which on a face whose database forces `Recreate`
                stops the pod before starting the new one. A declaration adopting such an object
                cannot write the safe value without scheduling the outage, and pretending otherwise
                would mean either a silent rollout or an adoption that never happens.

                So it is fenced on four sides rather than trusted: it demands a REASON rather than a
                boolean, it is refused unless the surface is `adopt`ing something, it is refused
                where nothing would have been refused anyway (an acknowledgement of a risk nobody is
                taking outlives the risk and starts reading as permission), and it warns at every
                render for as long as it stands. What it is NOT is a way to make the catalogue's
                knowledge optional: the risk does not go away because a deployment described it.
              '';
            };
          };
        });
      };

      probes = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          { startup   = { periodSeconds = 3; failureThreshold = 40; timeoutSeconds = 5; };
            readiness = { periodSeconds = 5; failureThreshold = 30; timeoutSeconds = 5; };
          }
        '';
        description = ''
          HOW PATIENT each probe is on THIS cluster, keyed by the SAME names the catalogue uses.
          Budgeting a probe the catalogue does not name, or leaving one it does name unbudgeted, is
          an eval error rather than a surprise at runtime — and a probe the catalogue REFUSES
          cannot be budgeted at all, with its reason quoted back.

          THE SPLIT, and why the numbers are here rather than in the catalogue. Which probes a face
          needs, and what answers them, is true of the software wherever it runs. A threshold is a
          stopwatch held against one cluster's disks: the first-boot migration that finishes inside
          ninety seconds on a mirror of SSDs takes minutes on a loaded spindle, and a number
          measured on somebody else's hardware is a restart loop on yours. Nothing is defaulted, for
          the same reason a floating tag is not a default — a patience nobody measured is not a
          value anyone may pick on somebody else's behalf.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            initialDelaySeconds = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 0;
              description = ''
                Delay before the first probe. The one number with a default, because zero is not a
                measurement — it is the absence of a delay, and a probe that starts immediately and
                is allowed to fail is the shape every budget below already describes.
              '';
            };
            periodSeconds = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Interval between probes.";
            };
            failureThreshold = lib.mkOption {
              type = lib.types.ints.positive;
              description = ''
                Consecutive failures before the verdict is acted on. With `periodSeconds` this is
                the whole budget: their product is how long a slow start is tolerated before the
                container is restarted or held out of the Service.
              '';
            };
            timeoutSeconds = lib.mkOption {
              type = lib.types.ints.positive;
              description = "How long one probe may take before it counts as failed.";
            };
          };
        });
      };

      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Environment this deployment adds, merged over what the catalogue sets. Values only —
          anything secret belongs in a Secret and arrives through `secrets`. The variables that
          describe the container's own insides, and the ones that carry the identity, are the
          catalogue's and setting one here is an eval error rather than an override.
        '';
      };

      secrets = lib.mkOption {
        default = { };
        description = ''
          Secrets this surface consumes, keyed by the Secret's own name, each naming which of its
          keys becomes which variable. Named rather than carried: nothing in this repository can
          hold a secret's contents, which is what makes a declaration written here publishable.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options.env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = { EXAMPLE_ENCRYPTION_KEY = "encryption-key"; };
            description = "`<VARIABLE> = \"<key in the Secret>\"`, rendered as a `secretKeyRef`.";
          };
        });
      };
    };
  };
in
{
  # The grammar, imported by the module that translates INTO it. The direction is the whole design:
  # this needs the grammar and the grammar must never need this.
  imports = [ ../apps ];

  options.nixk3s.cockpit = {
    origin = lib.mkOption {
      type = lib.types.str;
      default = "nixk3s";
      description = ''
        THE IDENTITY these surfaces are addressed under when the band model is part of the render.
        A repository naming itself is not a fleet fact — which band that name binds is, and it
        lives wherever the fleet is described. The default is this repository's own name because
        this repository is the one declaring them; a vendored copy declaring under another name
        says so here.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "management";
      description = ''
        Delivery project these surfaces land in unless a declaration says otherwise. The tenancy
        model's first tier, which is where the things that MANAGE the cluster belong — the same
        distinction that decides what may be catalogued here at all.
      '';
    };

    surfaces = lib.mkOption {
      default = { };
      description = ''
        The platform's own faces that run in this cluster, keyed by a name of your choosing.

        THE ENUM IS THE BOUNDARY. It is built from `lib/cockpit.nix`, so a workload this repository
        does not catalogue is not a refused value here — it is not a value. What may go into that
        catalogue is one test: a face belongs only if it would still be worth running on a cluster
        with no apps in it. Everything else is an app somebody HAS, and the grammar underneath is
        deliberately incurious about those.
      '';
      example = lib.literalExpression ''
        {
          example-portal = {
            face = "homarr";
            version = "0.0.0";
            namespace = "example-cockpit";
            createNamespace = true;
            exposure = "nb";
            slot = 42;
            posixIdentity = { uid = 4242; gid = 4242; };
            state.appdata.hostPath = "/example/state/example-portal";
            secrets.example-portal-secrets.env.SECRET_ENCRYPTION_KEY = "encryption-key";
          };
        }
      '';
      type = lib.types.attrsOf (lib.types.submodule surfaceOptions);
    };

    emptyStartAccepted = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.concatMap
        (x: lib.mapAttrsToList (key: _: "${x.name}.${key}")
          (lib.filterAttrs (_: b: b.emptyStartAccepted != null) x.s.state))
        surfaces;
      defaultText = lib.literalExpression
        "every `<surface>.<directory>` whose backing is allowed to create it when it is missing";
      description = ''
        The directories a declaration is allowed to start empty against, in the face of a catalogue
        entry saying they must already hold data. Read-only, and COUNTABLE on purpose, for the same
        reason the grammar counts its escape hatch: an exception nobody measures becomes the design.

        Every entry here is a live object that cannot take the safe backing without a rollout, so
        the list going down is a real migration and the list going up is a decision somebody made.
        A consumer can assert on it — most usefully that it is empty, or that it holds exactly the
        objects it held yesterday.
      '';
    };

    slots = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.unsigned;
      readOnly = true;
      default = lib.listToAttrs
        (map (x: lib.nameValuePair x.name x.s.slot) (lib.filter (x: x.s.slot != null) surfaces));
      defaultText = lib.literalExpression "every rendered surface that claims a slot";
      description = ''
        surface -> the position it claims. Nothing is rendered from it here: what an address looks
        like is the private layer's business, and this is what that layer reads to build one.
      '';
    };
  };

  config = {
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) surfaces);
    nixidy.assertions =
      stateAssertions ++ probeAssertions ++ envAssertions ++ identityAssertions ++ anchorAssertions
      ++ slotAssertions;
    nixidy.warnings = warnings;
  };
}
