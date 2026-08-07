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

    # A storage path wearing a claim name's clothes.
    claim-that-is-really-a-path =
      goodApp // { state.data = { claim = "/example/pool/appdata/example-app"; mountPath = "/data"; }; };

    # Guards against rendering something that cannot work.
    probe-on-an-undeclared-port =
      goodApp // { probe.port = "nonexistent"; };

    exposed-with-nothing-to-expose =
      { namespace = "example-apps"; image = goodApp.image; exposure = "public"; };

    wake-front-on-an-always-on-app =
      goodApp // { wake = "keda"; };

    gpu-scale-to-zero-fronted-by-the-wrong-thing =
      goodApp // { gpu = true; scaling = "scale-to-zero"; wake = "keda"; };
  };

  # Same shape, nothing wrong. If this one fails, the harness is broken.
  control = goodApp;

  wronglyRendered = lib.attrNames
    (lib.filterAttrs (_: v: v) (lib.mapAttrs
      (_: apps: renders { nixk3s.apps = apps; })
      mustFail));

  controlRenders = renders { nixk3s.apps.example-control = control; };

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
lib.throwIf (!controlRenders)
  "nixk3s.apps fail-closed check is broken: the control app does not render, so every negative case below proves nothing."
  (lib.throwIf (wronglyRendered != [ ])
    ("nixk3s.apps rendered declarations it must have refused: "
      + lib.concatStringsSep ", " wronglyRendered)
    (lib.throwIf gpuWithoutResourceName
      "nixk3s.apps rendered a GPU app while `appPlatform.gpuResourceName` was unset; the pod would schedule with no device and no error."
      (pkgs.writeText "nixk3s-apps-fail-closed" ''
        control renders, and every guard fires:
        ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames mustFail)}
          refused: gpu-without-a-named-device-resource
      '')))
