# Proves the grammar fails CLOSED: every guard in `nixk3s.apps` is checked in
# the failing direction, because a guard nobody has seen fire is a comment.
#
# Each case below is a complete, otherwise-valid app declaration with exactly
# one thing wrong, rendered through real nixidy. `builtins.tryEval` catches the
# resulting throw; a case that RENDERS is a failed check. The `control` case is
# the same shape with nothing wrong and must succeed — without it, a typo in
# the shared base would make every other case "pass" for the wrong reason.
{ pkgs, lib, nixidy, appsModule, tenancyModule }:
let
  base = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixk3s.tenancy = {
      enable = true;
      projects.apps.destinationNamespaces = [ "example-apps" ];
    };
    nixk3s.appPlatform.gpuResourceName = "example.com/gpu";
  };

  # A declaration that is fine on its own; each case perturbs one field.
  goodApp = {
    namespace = "example-apps";
    image = "registry.example.com/example-org/example-app:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222";
    ports.http.number = 8080;
  };

  renders = values:
    let
      env = nixidy.lib.mkEnv {
        inherit pkgs;
        modules = [ appsModule tenancyModule base values ];
      };
    in
    (builtins.tryEval (builtins.seq env.environmentPackage.drvPath true)).success;

  # name -> `nixk3s.apps` value, all of which MUST fail to render.
  mustFail = lib.mapAttrs (name: app: { ${name} = app; }) oneAppCases // {
    # The only case that needs two apps: one Namespace with two Argo owners.
    namespace-created-by-two-apps = {
      example-first = goodApp // { createNamespace = true; };
      example-second = goodApp // { createNamespace = true; };
    };
  };

  oneAppCases = {
    # LESSON 1: an Application outside its project's destinations is refused
    # wholesale by Argo CD, so it must never leave this repository.
    stranded-outside-project-destinations =
      goodApp // { namespace = "example-elsewhere"; };

    targets-a-project-tenancy-never-defines =
      goodApp // { project = "example-nonexistent"; };

    # The public boundary: fleet addresses cannot enter an app declaration.
    address-literal-in-env =
      goodApp // { env.EXAMPLE_PEER = "10.0.0.7"; };

    address-literal-in-image-registry =
      goodApp // { image = "10.0.0.7:5000/example-org/example-app:1.0.0"; };

    ipv6-literal-in-env =
      goodApp // { env.EXAMPLE_PEER = "fd00::42"; };

    # A storage path wearing a claim name's clothes. `hostPath` is the term for
    # a path, and it is a different thing with different consequences.
    claim-that-is-really-a-path =
      goodApp // { state.data = { claim = "/example/pool/appdata/example-app"; mountPath = "/data"; }; };

    # State needs exactly one backing — neither is not storage, and both is two
    # answers to a question with one answer.
    state-with-no-backing =
      goodApp // { state.data = { mountPath = "/data"; }; };

    state-with-both-backings =
      goodApp // {
        state.data = { claim = "example-data"; hostPath = "/example/data"; mountPath = "/data"; };
      };

    hostpath-that-is-not-absolute =
      goodApp // { state.data = { hostPath = "example/data"; mountPath = "/data"; }; };

    # A `hostPathType` on the backing that has no host path. `volumesOf` reads
    # the field on the hostPath side of the backing choice and nowhere else, so
    # this value used to be accepted, discarded, and — the part that matters —
    # never type-checked. Both halves are cases here: the declaration that means
    # nothing, and the one that is not even of the right type, because only the
    # second proves the value is now FORCED rather than merely compared.
    hostpath-type-on-claim-backed-state =
      goodApp // {
        state.data = { claim = "example-data"; mountPath = "/data"; hostPathType = "DirectoryOrCreate"; };
      };

    hostpath-type-outside-its-enum-on-claim-backed-state =
      goodApp // {
        state.data = { claim = "example-data"; mountPath = "/data"; hostPathType = "NotAKubernetesType"; };
      };

    # The same shape one level up: the Deployment renders `replicas` behind an
    # `mkIf` on `scaling == "always"`, so a sleeping app's count is discarded
    # before anything forces it, and any value at all used to render green.
    replica-count-on-an-app-that-sleeps =
      goodApp // { scaling = "scale-to-zero"; replicas = 2; };

    replica-count-that-is-not-a-count-on-an-app-that-sleeps =
      goodApp // { scaling = "scale-to-zero"; replicas = "two"; };

    # Secrets: named, consumed, and never a path or a value.
    secret-that-is-really-a-path =
      goodApp // { secrets.creds = { secret = "/example/secrets/app.env"; envFrom = true; }; };

    secret-referenced-but-never-consumed =
      goodApp // { secrets.creds = { secret = "example-app-credentials"; }; };

    secret-mount-that-is-not-absolute =
      goodApp // { secrets.creds = { secret = "example-app-credentials"; mountPath = "run/creds"; }; };

    # One variable, two sources: whichever wins, it is not what was meant.
    env-and-secret-collide-on-one-variable =
      goodApp // {
        env.EXAMPLE_TOKEN = "plain";
        secrets.creds.env.EXAMPLE_TOKEN = "token";
      };

    # Guards against rendering something that cannot work.
    probe-on-an-undeclared-port =
      goodApp // { probes.readiness.port = "nonexistent"; };

    liveness-probe-on-an-undeclared-port =
      goodApp // { probes.liveness.port = "nonexistent"; };

    exposed-with-nothing-to-expose =
      { namespace = "example-apps"; image = goodApp.image; exposure = "public"; };

    wake-front-on-an-always-on-app =
      goodApp // { wake = "keda"; };

    gpu-scale-to-zero-fronted-by-the-wrong-thing =
      goodApp // { gpu = true; scaling = "scale-to-zero"; wake = "keda"; };
  };

  # Same shape, nothing wrong. If one of these fails, the harness is broken and
  # every negative case above proves nothing.
  #
  # There are three because two of the cases perturb only a value the render
  # DISCARDS, and a case refused for the wrong reason passes this check
  # silently: without a sleeping control, "scale-to-zero was rejected at all"
  # would read as proof that the replica count was checked, and without a
  # claim-backed one the same goes for `hostPathType`.
  controls = {
    control = goodApp;
    sleeping-control = goodApp // { scaling = "scale-to-zero"; };
    claim-backed-control =
      goodApp // { state.data = { claim = "example-data"; mountPath = "/data"; }; };
  };

  wronglyRendered = lib.attrNames
    (lib.filterAttrs (_: v: v) (lib.mapAttrs
      (_: apps: renders { nixk3s.apps = apps; })
      mustFail));

  brokenControls = lib.attrNames
    (lib.filterAttrs (_: v: !v) (lib.mapAttrs
      (_: app: renders { nixk3s.apps.example-control = app; })
      controls));

  # A GPU app is also checked against a platform that has not named its device
  # resource — the "no silent default" guard, which needs a different base.
  gpuWithoutResourceName =
    let
      env = nixidy.lib.mkEnv {
        inherit pkgs;
        modules = [
          appsModule
          tenancyModule
          base
          {
            nixk3s.appPlatform.gpuResourceName = lib.mkForce null;
            nixk3s.apps.example-gpu = goodApp // { gpu = true; };
          }
        ];
      };
    in
    (builtins.tryEval (builtins.seq env.environmentPackage.drvPath true)).success;
in
lib.throwIf (brokenControls != [ ])
  ("nixk3s.apps fail-closed check is broken: these control apps do not render, so every negative case "
    + "below proves nothing: " + lib.concatStringsSep ", " brokenControls)
  (lib.throwIf (wronglyRendered != [ ])
    ("nixk3s.apps rendered declarations it must have refused: "
      + lib.concatStringsSep ", " wronglyRendered)
    (lib.throwIf gpuWithoutResourceName
      "nixk3s.apps rendered a GPU app while `appPlatform.gpuResourceName` was unset; the pod would schedule with no device and no error."
      (pkgs.writeText "nixk3s-apps-fail-closed" ''
        the controls render:
        ${lib.concatMapStringsSep "\n" (n: "  renders: ${n}") (lib.attrNames controls)}

        and every guard fires:
        ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames mustFail)}
          refused: gpu-without-a-named-device-resource
      '')))
