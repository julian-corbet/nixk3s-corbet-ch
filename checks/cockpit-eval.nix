# Proves the cockpit module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# surface with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render -- without it, a typo in the shared base would make every other case "pass" for
# the wrong reason.
#
# THREE OF THE REFUSALS ARE NOT GUARDS AT ALL. Naming a face the catalogue does not hold, leaving
# out the version, and leaving out the namespace fail as a type error and as missing required
# options -- not as assertions. That is the stronger kind: a boundary nobody has to remember,
# because it is unwritable rather than refused. `tryEval` cannot tell those apart from a guard, so
# the ones that ARE guards additionally have their message asserted by content.
#
# TWO ENVIRONMENTS, because one of the claims is about composition rather than about a value. The
# cockpit imports the grammar itself, so it must render with nothing else beside it; and it hands
# the band model its terms only when a surface claims a position, so claiming one without that
# module in the render has to say so rather than fail on an option that does not exist.
{ pkgs, lib, nixidy, cockpitModule, addressingModule, values }:

let
  base = import values;

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ cockpitModule addressingModule v ];
  };

  # The cockpit ALONE: no grammar named here, because the module carries it.
  mkEnvNoBandModel = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ cockpitModule v ];
  };

  # `tryEval` alone forces only WHNF. Forcing the derivation path is what actually runs the module
  # system's type checks and the assertions underneath.
  rendersIn = env: v: (builtins.tryEval (builtins.seq (env v).environmentPackage.drvPath true)).success;
  renders = rendersIn mkEnv;

  # An assertion fired, AND it is the one meant: a refusal that happens for an unrelated reason is
  # a false pass, which is exactly the failure this repository's checks exist to make impossible.
  failsWithIn = env: infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (env v).config.nixidy.assertions);
    in
    r.success && r.value;
  failsWith = failsWithIn mkEnv;

  warnsWith = infix: v:
    lib.any (w: w.when && lib.hasInfix infix w.message) (mkEnv v).config.nixidy.warnings;

  # A surface with nothing declared at all, to prove the module is inert until something asks.
  emptyCfg = (mkEnv {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
  }).config;

  goodCfg = (mkEnv base).config;

  with' = f: lib.recursiveUpdate base f;

  # The parked declaration, woken up. Every case that needs a SECOND rendered surface starts here,
  # because a second surface that is invalid for its own reasons would refuse for the wrong one.
  secondSurface = extra: with' {
    nixk3s.cockpit.surfaces.example-parked-portal = {
      enable = true;
      posixIdentity = { uid = 4343; gid = 4343; };
      state.appdata.hostPath = "/example/state/example-parked-portal";
      secrets.example-parked-secrets.env.SECRET_ENCRYPTION_KEY = "encryption-key";
    } // extra;
  };

  # The minimum a surface has to say, without the band model in the render at all.
  aloneWith = extra: {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixk3s.cockpit.surfaces.example-portal = {
      face = "homarr";
      version = "0.0.0";
      namespace = "example-cockpit";
      posixIdentity = { uid = 4242; gid = 4242; };
      state.appdata.hostPath = "/example/state/example-portal";
      secrets.example-portal-secrets.env.SECRET_ENCRYPTION_KEY = "encryption-key";
    } // extra;
  };

  results = {
    # ── The control, and the floor ────────────────────────────────────────────────────────────
    "the example surface renders -- without this every refusal below could pass for the wrong reason" =
      renders base;

    "an undeclared cockpit renders no apps at all, rather than a default one" =
      emptyCfg.nixk3s.apps == { };

    "a parked declaration is a declaration that renders nothing" =
      lib.attrNames goodCfg.nixk3s.apps == [ "example-portal" ];

    # ── What the module IS: a translator over a grammar it carries ────────────────────────────
    "the cockpit alone composes the grammar it defines into, with nothing else in the render" =
      rendersIn mkEnvNoBandModel (aloneWith { });

    "the catalogue supplies the port, and the declaration never states one" =
      goodCfg.nixk3s.apps.example-portal.ports.http.number == 7575;

    "a version becomes the tag, and a whole reference overrides it" =
      lib.hasInfix "@sha256:" goodCfg.nixk3s.apps.example-portal.image
      && (mkEnv (lib.recursiveUpdate base {
        nixk3s.cockpit.surfaces.example-portal.image = lib.mkForce null;
      })).config.nixk3s.apps.example-portal.image == "ghcr.io/homarr-labs/homarr:0.0.0";

    "the catalogue supplies WHERE a directory lives and the declaration supplies WHAT BACKS IT" =
      goodCfg.nixk3s.apps.example-portal.state.appdata.mountPath == "/appdata"
      && goodCfg.nixk3s.apps.example-portal.state.appdata.hostPath == "/example/state/example-portal";

    "the catalogue owns the datastores' own paths, and they land inside the backed directory" =
      lib.hasPrefix
        goodCfg.nixk3s.apps.example-portal.state.appdata.mountPath
        goodCfg.nixk3s.apps.example-portal.env.DB_URL;

    "the image starting as root is knowledge, and the identity it drops to is a value" =
      goodCfg.nixk3s.apps.example-portal.identity == "root"
      && goodCfg.nixk3s.apps.example-portal.env.PUID == "4242"
      && goodCfg.nixk3s.apps.example-portal.env.PGID == "4242";

    "a Secret is named and never carried" =
      goodCfg.nixk3s.apps.example-portal.secrets.example-portal-secrets.env.SECRET_ENCRYPTION_KEY
      == "encryption-key";

    "the band model gets its terms because a position was claimed, and the report holds it" =
      goodCfg.nixk3s.apps.example-portal.origin == "nixk3s"
      && goodCfg.nixk3s.apps.example-portal.slot == 33
      && goodCfg.nixk3s.cockpit.slots == { example-portal = 33; };

    # ── Unwritable, not merely refused ────────────────────────────────────────────────────────
    "a face the catalogue does not hold is not a value this option has" =
      !renders (with' { nixk3s.cockpit.surfaces.example-portal.face = "nonesuch"; });

    "a surface with no version is refused, because a floating tag is not a default anyone can pick" =
      !rendersIn mkEnvNoBandModel {
        nixidy.target.repository = "https://example.com/x.git";
        nixidy.target.branch = "main";
        nixk3s.cockpit.surfaces.x = { face = "homarr"; namespace = "example-cockpit"; };
      };

    "a surface with no namespace is refused, because which namespaces exist is one cluster's shape" =
      !rendersIn mkEnvNoBandModel {
        nixidy.target.repository = "https://example.com/x.git";
        nixidy.target.branch = "main";
        nixk3s.cockpit.surfaces.x = { face = "homarr"; version = "0.0.0"; };
      };

    # ── The guards, each with its message asserted ────────────────────────────────────────────
    "backing a directory the face does not write is refused" =
      failsWith "must back every directory it writes"
        (with' { nixk3s.cockpit.surfaces.example-portal.state.nonesuch.hostPath = "/example/nope"; });

    "leaving the directory it DOES write unbacked is refused" =
      failsWith "must back every directory it writes"
        (lib.recursiveUpdate base {
          nixk3s.cockpit.surfaces.example-portal.state = lib.mkForce { };
        });

    "a directory backed by both a claim and a node path is refused" =
      failsWith "EITHER an existing claim"
        (with' { nixk3s.cockpit.surfaces.example-portal.state.appdata.claim = "example-claim"; });

    "a directory that must already hold data may not be backed by one that gets created" =
      failsWith "must already hold data"
        (with' { nixk3s.cockpit.surfaces.example-portal.state.appdata.hostPathType = "DirectoryOrCreate"; });

    "redefining a variable that describes the container's own insides is refused" =
      failsWith "which the catalogue owns"
        (with' { nixk3s.cockpit.surfaces.example-portal.env.DB_URL = "/example/elsewhere/db.sqlite"; });

    "spelling the identity as a variable instead of as two numbers is refused" =
      failsWith "which the catalogue owns"
        (with' { nixk3s.cockpit.surfaces.example-portal.env.PUID = "0"; });

    "a value that must survive every restart unchanged must come from a Secret" =
      failsWith "takes it from nothing"
        (lib.recursiveUpdate base {
          nixk3s.cockpit.surfaces.example-portal.secrets = lib.mkForce { };
        });

    "writing that value into the tree instead is refused" =
      failsWith "as a plain value"
        (with' {
          nixk3s.cockpit.surfaces.example-portal.env.SECRET_ENCRYPTION_KEY = "example-placeholder";
        });

    "an image that drops privileges and is handed no identity is refused" =
      failsWith "no `posixIdentity` says which one"
        (lib.recursiveUpdate base {
          nixk3s.cockpit.surfaces.example-portal.posixIdentity = lib.mkForce null;
        });

    "two surfaces anchoring one namespace is refused" =
      failsWith "Exactly one surface may create a namespace"
        (secondSurface { namespace = "example-cockpit"; createNamespace = true; });

    "two surfaces on one position is refused" =
      failsWith "is claimed by 2 surfaces"
        (secondSurface { namespace = "example-parked-cockpit"; slot = 33; });

    "claiming a position with no band model in the render is refused, by name" =
      failsWithIn mkEnvNoBandModel "the band model is not part of this render"
        (aloneWith { slot = 33; });

    # ── The warnings, which are not refusals ──────────────────────────────────────────────────
    # Both are real mistakes and neither is an eval error, for the same reason: what a cluster
    # routes and what sits in front of a face are things one deployment can see and this repository
    # cannot.
    "scale-to-zero with no wake front warns rather than refuses" =
      warnsWith "nothing brings it back"
        (lib.recursiveUpdate base { nixk3s.cockpit.surfaces.example-portal.wake = lib.mkForce null; });

    "a face on the internet that selects no authentication provider warns" =
      warnsWith "how it authenticates anybody"
        (lib.recursiveUpdate base {
          nixk3s.cockpit.surfaces.example-portal.env = lib.mkForce { TZ = "UTC"; };
        });
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in
pkgs.runCommand "nixk3s-cockpit-eval" { } (
  if failed == [ ]
  then ''
    echo "nixk3s: all ${toString (lib.length (lib.attrNames results))} cockpit-eval properties hold"
    touch $out
  ''
  else ''
    echo "nixk3s cockpit-eval FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):" >&2
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}" >&2'') failed}
    exit 1
  ''
)
