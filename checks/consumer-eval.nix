# Proves the consumer factory REFUSES what it claims to refuse, through the real renderer and the
# real app grammar.
#
# The render check proves what comes out when a declaration is right. This proves what happens when
# one is wrong, which is the half that keeps thirteen catalogues safe: every guard here is the only
# thing standing between a plausible-looking declaration and a workload that starts misconfigured
# and fails later, further from the cause.
#
# Every case is a complete, otherwise-valid surface with EXACTLY ONE thing wrong, and the control
# case is the same shape with nothing wrong. Without the control, a typo in the shared base would
# make every other case "pass" for the wrong reason -- a guard that fires on everything is a wall,
# not a guard.
#
# A refusal is asserted BY MESSAGE, not merely by failing. `tryEval` cannot tell a guard from a
# type error or a missing attribute, so a case that refused for an unrelated reason would look
# exactly like a case that worked. That is the specific false pass this file exists to prevent.
{ pkgs, lib, nixidy, appsModule, consumerModule, values }:

let
  base = import values { };

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule consumerModule v ];
  };

  # `tryEval` alone forces only WHNF. Forcing the derivation path is what actually runs the module
  # system's type checks and the assertions underneath.
  renders = v: (builtins.tryEval (builtins.seq (mkEnv v).environmentPackage.drvPath true)).success;

  failsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (mkEnv v).config.nixidy.assertions);
    in
    r.success && r.value;

  warnsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (w: w.when && lib.hasInfix infix w.message)
        (mkEnv v).config.nixidy.warnings);
    in
    r.success && r.value;

  emptyCfg = (mkEnv {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
  }).config;

  with' = f: lib.recursiveUpdate base f;

  results = {
    # ── The control, and the floor ───────────────────────────────────────────────────────────
    "the example surface renders -- without this every refusal below could pass for the wrong reason" =
      renders base;

    "an undeclared surface renders no apps at all, rather than a default one" =
      emptyCfg.nixk3s.apps == { };

    "both declared workloads reach the grammar" =
      lib.sort (a: b: a < b) (lib.attrNames (mkEnv base).config.nixk3s.apps) == [ "one" "two" ];

    # ── The split, refused in both directions ────────────────────────────────────────────────
    "a directory the catalogue names and nothing backs is refused" =
      failsWith "must back every directory it writes"
        (with' { nixconsumer.applications.one.state = lib.mkForce { }; });

    # The declaration-only direction, and the reason it needs its own case: every other guard
    # indexes the catalogue by a declaration's key, so a key the catalogue has never heard of used
    # to throw a missing-attribute error while the assertion explaining the mistake was still being
    # collected. The author got a crash where a sentence was waiting for them.
    "backing a directory the catalogue does not name gives a MESSAGE, not a crash" =
      failsWith "must back every directory it writes"
        (with' { nixconsumer.applications.one.state.not-a-directory.hostPath = "/example/nope"; });

    "a directory with no backing at all is refused" =
      failsWith "EXACTLY ONE of a claim"
        (with' { nixconsumer.applications.one.state.data = lib.mkForce { }; });

    "a directory with TWO backings is refused -- the other half of the same guard" =
      failsWith "EXACTLY ONE of a claim"
        (with' { nixconsumer.applications.one.state.data.claim = "example-second-backing"; });

    "a scratch directory counts as a backing, so it renders" =
      renders (with' {
        nixconsumer.applications.two.state.reference = lib.mkForce { emptyDir = true; };
      });

    "asking the kubelet to own a directory the catalogue says GROWS is refused" =
      failsWith "GROWS"
        (with' { nixconsumer.applications.one.state.data-archive.ownership = "kubelet"; });

    # The example names its nested pair so the outer sorts first. Forcing the inner one to sort
    # earlier is the mistake this guard exists for, and it is invisible at runtime: the outer mount
    # is laid over the inner, the data is still on the disk, and the workload comes up healthy
    # against a directory it can no longer see.
    "a nested mount whose name sorts before its parent is refused" =
      failsWith "sort the wrong way round"
        (with' { nixconsumer.applications.one.state.data-archive.volumeName = "aaa-archive"; });

    "the same ownership on a directory that does not grow renders" =
      renders (with' { nixconsumer.applications.two.state.reference.ownership = "kubelet"; });

    "a budget for a probe the software does not warrant is refused" =
      failsWith "does not warrant"
        (with' { nixconsumer.applications.one.probes.startup.failureThreshold = 60; });

    # Taking the DEFAULT Secret away while a per-variable override survives: the overridden
    # variable is still delivered and the other is not, which is exactly the partial coverage the
    # old single-Secret assertion could not see.
    "a credential variable nothing delivers is refused, even when its sibling is covered" =
      failsWith "names no Secret to deliver"
        (with' { nixconsumer.applications.one.credentials.secret = lib.mkForce null; });

    "a Secret named by a workload that reads no credential is refused" =
      failsWith "reads no credential"
        (with' { nixconsumer.applications.two.credentials.secret = "example-unused"; });

    "a key mapped for a variable the catalogue does not list is refused" =
      failsWith "does not read"
        (with' { nixconsumer.applications.one.credentials.keys.ALPHA_NOT_A_VARIABLE = "x"; });

    # ── Idling is a correctness question ─────────────────────────────────────────────────────
    "scaling to zero what the catalogue says cannot idle is refused" =
      failsWith "unsafe to idle"
        (with' {
          nixconsumer.applications.one.scaling = "scale-to-zero";
          nixconsumer.applications.one.wake = "keda";
        });

    "the same workload left always-on renders" =
      renders (with' { nixconsumer.applications.one.scaling = "always"; });

    # ── Knowing where things are ─────────────────────────────────────────────────────────────
    "a needed service the declaration never locates is refused" =
      failsWith "is not told where to find"
        (with' { nixconsumer.applications.one.requires = lib.mkForce { }; });

    "an endpoint for something the software does not read is refused" =
      failsWith "does not read"
        (with' { nixconsumer.applications.one.requires.nothing.endpoint = "http://example-nothing"; });

    "an endpoint that does not speak the protocol the catalogue names is refused" =
      failsWith "does not speak the protocol"
        (with' { nixconsumer.applications.one.requires.index.endpoint = lib.mkForce "redis://example-index:6379"; });

    "a literal address instead of a service name is refused" =
      failsWith "literal ADDRESS"
        (with' { nixconsumer.applications.one.requires.index.endpoint = lib.mkForce "http://10.0.0.5:9200"; });

    "an IPv6 literal is refused too" =
      failsWith "literal ADDRESS"
        (with' { nixconsumer.applications.one.requires.index.endpoint = lib.mkForce "http://[fd00::1]:9200"; });

    "a hostname that merely contains digits is NOT an address" =
      renders (with' { nixconsumer.applications.one.requires.index.endpoint = lib.mkForce "http://index9:9200"; });

    "a public URL nothing would read is refused" =
      failsWith "reads no variable to carry one"
        (with' { nixconsumer.applications.two.publicUrl = "https://example.com"; });

    # ── Addressing ───────────────────────────────────────────────────────────────────────────
    "two workloads on one slot is refused" =
      failsWith "is claimed by 2 workloads"
        (with' { nixconsumer.applications.two.slot = 40; });

    "two workloads anchoring one namespace is refused" =
      failsWith "is anchored by 2 workloads"
        (with' {
          nixconsumer.applications.two.namespace = "example-consumer";
          nixconsumer.applications.two.createNamespace = true;
        });

    # ── The warnings, which are deliberately NOT refusals ────────────────────────────────────
    # Which front a cluster runs is its own business, and a factory that refused the combination
    # would be legislating routing it cannot see.
    "sleeping with nothing to wake it warns rather than refuses" =
      warnsWith "nothing brings it back"
        (with' {
          nixconsumer.applications.two.scaling = "scale-to-zero";
          nixconsumer.applications.two.wake = lib.mkForce null;
        });

    "a slot claimed with no origin warns, because nothing checks its range" =
      warnsWith "is unset" base;

    "a pod left looser than the software tolerates stays countable" =
      warnsWith "renders no securityContext"
        (with' { nixconsumer.applications.one.harden = false; });

    # ── Things that are unwritable rather than refused ───────────────────────────────────────
    # The stronger kind of boundary: nobody has to remember them, because the option does not exist.
    "a catalogue entry that does not exist cannot be named" =
      !renders (with' { nixconsumer.applications.one.app = "not-in-the-catalogue"; });

    "a securityContext cannot be written by hand" =
      !renders (with' { nixconsumer.applications.one.securityContext.runAsUser = 0; });

    "a raw resource map cannot be smuggled in beside the four named scalars" =
      !renders (with' { nixconsumer.applications.one.resources.limits."example.com/device" = "1"; });
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in

pkgs.runCommand "nixk3s-consumer-eval" { } ''
  ${lib.optionalString (failed != [ ]) ''
    echo "nixk3s consumer-eval FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):"
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}"'') failed}
    exit 1
  ''}
  echo "nixk3s: all ${toString (lib.length (lib.attrNames results))} consumer-eval properties hold"
  touch $out
''
