# Proves the grammar fails CLOSED: every guard in `nixk3s.apps` is checked in
# the failing direction, because a guard nobody has seen fire is a comment.
#
# Each case below is a complete, otherwise-valid app declaration with exactly
# one thing wrong, rendered through real nixidy. `builtins.tryEval` catches the
# resulting throw; a case that RENDERS is a failed check. The `control` cases are
# the same shape with nothing wrong and must succeed — without them, a typo in
# the shared base would make every other case "pass" for the wrong reason.
#
# AND EVERY REFUSAL MUST COME WITH A MESSAGE. `tryEval` can only say THAT a
# declaration was refused, so a case that is refused by a typo, or by a guard
# other than the one it was written for, passes silently. So the assertion-shaped
# cases are also read back through `applications.<app>.assertions` — where this
# grammar states them — and one that produces no failing assertion at all fails
# this check. The ILL-TYPED cases are held
# separately and never read that way, deliberately: an ill-typed definition
# throws while the assertion list is being BUILT, so there is no message to
# read and asking for one would throw rather than return.
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
    # One role, so the identity cases have something real to resolve against
    # and something real to miss. The registry may never define `root`, which
    # is its own case below.
    nixk3s.appPlatform.identities.example-role = { uid = 4242; gid = 4242; };
  };

  # A declaration that is fine on its own; each case perturbs one field.
  goodApp = {
    namespace = "example-apps";
    image = "registry.example.com/example-org/example-app:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222";
    ports.http.number = 8080;
  };

  companionImage = "registry.example.com/example-org/example-front:1.0.0@sha256:4444444444444444444444444444444444444444444444444444444444444444";

  # The same, with a second container in the pod — the base for every case that
  # perturbs something about a companion rather than about the app.
  goodMulti = goodApp // {
    companions.web = {
      image = companionImage;
      ports.front.number = 8081;
    };
  };

  mkEnv = values: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule tenancyModule base values ];
  };

  renders = values:
    (builtins.tryEval (builtins.seq (mkEnv values).environmentPackage.drvPath true)).success;

  # The assertions themselves, rather than the throw they eventually cause.
  # This grammar states them PER APPLICATION — `applications.<app>.assertions` —
  # so they are read from there and not from the environment-wide list, which
  # only carries what a module wrote to `nixidy.assertions` directly.
  failures = values:
    lib.concatLists (lib.mapAttrsToList
      (_: app: map (a: a.message) (lib.filter (a: !a.assertion) app.assertions))
      (mkEnv values).config.applications);

  # Cases refused by a GUARD, which therefore owe a message.
  assertionCases = lib.mapAttrs (name: app: { nixk3s.apps.${name} = app; }) oneAppCases // {
    # The only case that needs two apps: one Namespace with two Argo owners.
    namespace-created-by-two-apps.nixk3s.apps = {
      example-first = goodApp // { createNamespace = true; };
      example-second = goodApp // { createNamespace = true; };
    };
  };

  # Cases refused by the TYPE SYSTEM, which cannot. Each perturbs a value some
  # render site reads only on one side of a branch, so before the guard that
  # reads it existed, the value was accepted, discarded, and never checked.
  typeCases = lib.mapAttrs (name: app: { nixk3s.apps.${name} = app; }) illTypedCases;

  # Every declaration that MUST fail to render, whichever way it is stopped.
  mustFail = assertionCases // typeCases;

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

    # The same shape one level up: the Deployment renders `replicas` behind an
    # `mkIf` on `scaling == "always"`, so a sleeping app's count is discarded
    # before anything forces it, and any value at all used to render green.
    replica-count-on-an-app-that-sleeps =
      goodApp // { scaling = "scale-to-zero"; replicas = 2; };

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

    ## -------------------------------------------------------------------
    ## The volume noun, now that it has five backings and many views
    ## -------------------------------------------------------------------

    state-with-two-of-the-five-backings =
      goodApp // { state.cfg = { configMap = "example-config"; emptyDir = true; mountPath = "/cfg"; }; };

    # Two more name fields, the same rule: a name is not a path.
    configmap-that-is-really-a-path =
      goodApp // { state.cfg = { configMap = "/example/config"; mountPath = "/cfg"; }; };

    state-secret-that-is-really-a-path =
      goodApp // { state.cfg = { secret = "/example/secrets/app.env"; mountPath = "/cfg"; }; };

    # `mountPath` is the single-mount shorthand for what `mounts` says at
    # length; giving both is two answers to one question.
    mounts-and-mountpath-on-one-volume =
      goodApp // {
        state.data = {
          claim = "example-data";
          mountPath = "/data";
          mounts = [{ mountPath = "/data-again"; }];
        };
      };

    # Only reachable now that `mountPath` may be null: a volume nothing reads is
    # a typo, not a declaration.
    state-no-container-mounts =
      goodApp // { state.data.claim = "example-data"; };

    mount-path-that-is-not-absolute =
      goodApp // { state.data = { claim = "example-data"; mounts = [{ mountPath = "data"; }]; }; };

    subpath-that-is-absolute =
      goodApp // {
        state.data = { claim = "example-data"; mounts = [{ mountPath = "/data"; subPath = "/etc"; }]; };
      };

    subpath-that-escapes-the-volume =
      goodApp // {
        state.data = { claim = "example-data"; mounts = [{ mountPath = "/data"; subPath = "../etc"; }]; };
      };

    # `volumeMounts` merges on the path, so one of these is invisible and which
    # one depends on emission order.
    two-volumes-on-one-path-in-one-container =
      goodApp // {
        state.one = { claim = "example-one"; mountPath = "/data"; };
        state.two = { claim = "example-two"; mountPath = "/data"; };
      };

    # The second and later mounts of a volume take the key `<volume>-NN`, so a
    # volume already named that silently loses one of them.
    state-key-colliding-with-an-ordinal-mount-key =
      goodApp // {
        state.data = {
          claim = "example-data";
          mounts = [{ mountPath = "/data"; } { mountPath = "/data-more"; }];
        };
        state.data-01 = { claim = "example-data-01"; mountPath = "/other"; };
      };

    # `items` describes a projection only a keyed backing has.
    items-on-a-backing-with-no-keys =
      goodApp // {
        state.data = { hostPath = "/example/data"; mountPath = "/data"; items."app.conf" = "app.conf"; };
      };

    items-path-that-is-absolute =
      goodApp // {
        state.cfg = { configMap = "example-config"; mountPath = "/cfg"; items."app.conf" = "/etc/app.conf"; };
      };

    items-path-that-escapes-the-volume =
      goodApp // {
        state.cfg = { configMap = "example-config"; mountPath = "/cfg"; items."app.conf" = "../app.conf"; };
      };

    ## -------------------------------------------------------------------
    ## Identity: a role here, numbers at the site, and nothing silently dropped
    ## -------------------------------------------------------------------

    identity-the-site-never-defined =
      goodApp // { identity = "example-undefined"; };

    identity-env-that-names-a-number-nothing-supplies =
      goodApp // { identityEnv.user = "EXAMPLE_UID"; };

    identity-env-colliding-with-a-plain-variable =
      goodApp // {
        identity = "example-role";
        identityEnv.user = "EXAMPLE_UID";
        env.EXAMPLE_UID = "1000";
      };

    kubelet-ownership-of-a-backing-with-no-files-to-own =
      goodApp // {
        identity = "example-role";
        state.cfg = { configMap = "example-config"; mountPath = "/cfg"; ownership = "kubelet"; };
      };

    kubelet-ownership-with-no-identity-to-chown-to =
      goodApp // {
        state.data = { claim = "example-data"; mountPath = "/data"; ownership = "kubelet"; };
      };

    # This vocabulary only restricts, on every container in the pod.
    app-that-grants-privilege-escalation =
      goodApp // { security.allowPrivilegeEscalation = true; };

    companion-that-grants-privilege-escalation =
      goodApp // {
        companions.web = { image = companionImage; security.allowPrivilegeEscalation = true; };
      };

    init-container-that-grants-privilege-escalation =
      goodApp // {
        init = [{ name = "example-step"; image = companionImage; security.allowPrivilegeEscalation = true; }];
      };

    # `Recreate` serializes the ROLLOUT, not a replica count you asked for.
    single-writer-with-two-replicas =
      goodApp // { singleWriter = true; replicas = 2; };

    ## -------------------------------------------------------------------
    ## The pod, now that it may hold more than one container
    ## -------------------------------------------------------------------

    # The API server refuses such a pod, and inside an attrset the collision is
    # invisible: one of them simply does not exist.
    two-containers-with-one-name =
      goodApp // { name = "example-twin"; companions.example-twin.image = companionImage; };

    two-init-containers-with-one-name =
      goodApp // {
        init = [
          { name = "example-step"; image = companionImage; }
          { name = "example-step"; image = companionImage; }
        ];
      };

    # A port name is the POD's, not the container's: `targetPort` by name would
    # reach whichever container the attribute sort put last.
    port-name-claimed-by-two-containers =
      goodApp // { companions.web = { image = companionImage; ports.http.number = 8081; }; };

    # A volume is declared once, on the app. The kubelet would refuse the pod;
    # this is the cheaper place to find out.
    companion-mounting-a-volume-the-app-does-not-declare =
      goodApp // {
        companions.web = { image = companionImage; mounts.nowhere = [{ mountPath = "/srv"; }]; };
      };

    init-container-mounting-a-volume-the-app-does-not-declare =
      goodApp // {
        init = [{ name = "example-step"; image = companionImage; mounts.nowhere = [{ mountPath = "/srv"; }]; }];
      };

    companion-mount-that-is-not-absolute =
      goodApp // {
        state.data = { claim = "example-data"; mountPath = "/data"; };
        companions.web = { image = companionImage; mounts.data = [{ mountPath = "data"; }]; };
      };

    companion-subpath-that-escapes-the-volume =
      goodApp // {
        state.data = { claim = "example-data"; mountPath = "/data"; };
        companions.web = {
          image = companionImage;
          mounts.data = [{ mountPath = "/data"; subPath = "../etc"; }];
        };
      };

    # A typo here silently withholds a credential, and the app fails later,
    # further from the cause.
    secret-addressed-to-a-container-that-does-not-exist =
      goodApp // {
        secrets.creds = {
          secret = "example-app-credentials";
          env.EXAMPLE_TOKEN = "token";
          containers = [ "example-nonexistent" ];
        };
      };

    # A variable defined twice on ONE container, where the app's own container
    # is fine — the collision guard has to be per container to see this.
    env-and-secret-collide-on-one-companion =
      goodApp // {
        companions.web = { image = companionImage; env.EXAMPLE_TOKEN = "plain"; };
        secrets.creds = {
          secret = "example-app-credentials";
          env.EXAMPLE_TOKEN = "token";
          containers = [ "web" ];
        };
      };

    # A probe reads a socket through its OWN container's port table. Both
    # directions, because a pod-wide check would accept both.
    companion-probing-a-port-it-does-not-declare =
      goodMulti // {
        companions.web = { image = companionImage; ports.front.number = 8081; probes.readiness.port = "http"; };
      };

    app-probing-a-companions-port =
      goodMulti // { probes.readiness.port = "front"; };

    # The free-text surface a second container opens, closed by the same scan.
    address-literal-in-a-companions-env =
      goodApp // { companions.web = { image = companionImage; env.EXAMPLE_PEER = "10.0.0.7"; }; };

    address-literal-in-a-companions-image-registry =
      goodApp // { companions.web.image = "10.0.0.7:5000/example-org/example-front:1.0.0"; };

    address-literal-in-an-init-containers-args =
      goodApp // {
        init = [{ name = "example-wait"; image = companionImage; args = [ "--peer=10.0.0.7" ]; }];
      };

    # "Nothing to expose" now means nothing PUBLISHED, not "no ports".
    exposed-with-every-port-unpublished =
      goodApp // { exposure = "public"; ports.http = { number = 8080; publish = false; }; };

    # And the same discarded-value shape one more time: `mkService` is the only
    # reader of `servicePort`, and it no longer runs for an app that publishes
    # nothing — so without a guard this value is never even type-checked.
    service-port-on-a-port-that-is-never-published =
      goodApp // { ports.http = { number = 8080; publish = false; servicePort = 80; }; };
  };

  # THE OTHER HALF OF EVERY "EXISTS FOR WHAT IT FORCES" GUARD, held apart
  # because these are refused by the type system and therefore carry no message.
  #
  # Each perturbs a value that some render site reads on ONE side of a branch
  # and nowhere else, so before the guard that reads it unconditionally existed,
  # the value was accepted, discarded, and never type-checked. Only the ill-typed
  # half proves the value is FORCED rather than merely compared — a guard that
  # compares `x == null` never forces what `x` actually is.
  illTypedCases = {
    # `volumesOf` reads `hostPathType` on the hostPath side of the backing chain.
    hostpath-type-outside-its-enum-on-claim-backed-state =
      goodApp // {
        state.data = { claim = "example-data"; mountPath = "/data"; hostPathType = "NotAKubernetesType"; };
      };

    # `mkDeployment` renders `replicas` behind an `mkIf` on `scaling`.
    replica-count-that-is-not-a-count-on-an-app-that-sleeps =
      goodApp // { scaling = "scale-to-zero"; replicas = "two"; };

    # `itemsOf` reads `items` on the two KEYED branches of the backing chain.
    # This case sits on a backing that does have keys, so the projection itself
    # is legal and only the type is wrong.
    items-path-that-is-not-a-path =
      goodApp // {
        state.cfg = { configMap = "example-config"; mountPath = "/cfg"; items."app.conf" = 12345; };
      };

    # `mkService` is the only reader of `servicePort`, and it now sits behind
    # `rendersService` — so on an app that publishes nothing it is never read.
    service-port-that-is-not-a-port-on-an-app-that-publishes-nothing =
      goodApp // { ports.http = { number = 8080; publish = false; servicePort = "eighty"; }; };
  };

  # Same shape, nothing wrong. If one of these fails, the harness is broken and
  # every negative case above proves nothing.
  #
  # Several of the cases perturb only a value the render DISCARDS, and a case
  # refused for the wrong reason passes this check silently: without a sleeping
  # control, "scale-to-zero was rejected at all" would read as proof that the
  # replica count was checked, and without a claim-backed one the same goes for
  # `hostPathType`. The multi-container controls are there for the same reason
  # at the other end — "a companion was rejected at all" must not be what makes
  # twenty companion cases look green.
  controls = {
    control = goodApp;
    sleeping-control = goodApp // { scaling = "scale-to-zero"; };
    claim-backed-control =
      goodApp // { state.data = { claim = "example-data"; mountPath = "/data"; }; };

    # A second container in the pod, with its own port, mount, probe and
    # credential — every shape the cases above perturb, all of it legal here.
    multi-container-control = goodMulti // {
      state.data = { claim = "example-data"; mountPath = "/data"; };
      state.cfg = { configMap = "example-config"; };
      companions.web = {
        image = companionImage;
        ports.front = { number = 8081; servicePort = 8080; };
        mounts.data = [{ mountPath = "/srv"; readOnly = true; }];
        mounts.cfg = [{ mountPath = "/etc/front.conf"; subPath = "front.conf"; readOnly = true; }];
        probes.readiness.port = "front";
        security.allowPrivilegeEscalation = false;
      };
      init = [{
        name = "example-step";
        image = companionImage;
        mounts.data = [{ mountPath = "/srv"; }];
      }];
      secrets.creds = {
        secret = "example-app-credentials";
        env.EXAMPLE_TOKEN = "token";
        containers = [ "web" "example-control" ];
      };
    };

    # An identity resolved from the registry, in both spellings a real app uses,
    # plus every restricting class at once.
    identity-control = goodApp // {
      identity = "example-role";
      security = {
        runAsNonRoot = true;
        seccomp = "RuntimeDefault";
        allowPrivilegeEscalation = false;
        readOnlyRootFilesystem = false;
        capabilitiesDrop = [ "ALL" ];
      };
      state.data = { claim = "example-data"; mountPath = "/data"; ownership = "kubelet"; };
    };

    env-identity-control = goodApp // {
      identity = "example-role";
      identityEnv = { user = "EXAMPLE_UID"; group = "EXAMPLE_GID"; };
      singleWriter = true;
    };

    # The reserved sentinel: said out loud rather than left to be inferred.
    root-identity-control = goodApp // { identity = "root"; };

    # An app that declares a real port and publishes none of it renders no
    # Service, and is therefore legal with `exposure = "internal"`. Without this
    # control, "exposed-with-every-port-unpublished was refused" would read as
    # proof of a guard when it might only mean `publish` breaks everything.
    unpublished-control = goodApp // { ports.metrics = { number = 9100; publish = false; }; };

    # And the mirror: an app with no ports of its own whose companion holds the
    # published one. It renders a Service; the app container never does.
    companion-only-port-control = {
      namespace = "example-apps";
      image = goodApp.image;
      exposure = "public";
      companions.web = { image = companionImage; ports.http = { number = 8080; servicePort = 80; }; };
    };
  };

  wronglyRendered =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) mustFail));

  # A case refused without an assertion of its own was stopped by something
  # other than the guard it was written for — a typo in the case, or a
  # neighbouring guard firing first — and proves nothing about that guard.
  silentlyRefused =
    lib.attrNames (lib.filterAttrs (_: values: failures values == [ ]) assertionCases);

  brokenControls = lib.attrNames
    (lib.filterAttrs (_: v: !v) (lib.mapAttrs
      (_: app: renders { nixk3s.apps.example-control = app; })
      controls));

  # Two guards are about the PLATFORM rather than about one app, so they need a
  # different base than `mustFail` builds.
  withPlatform = values:
    let
      env = nixidy.lib.mkEnv {
        inherit pkgs;
        modules = [ appsModule tenancyModule base values ];
      };
    in
    (builtins.tryEval (builtins.seq env.environmentPackage.drvPath true)).success;

  # A GPU app checked against a platform that has not named its device
  # resource — the "no silent default" guard.
  gpuWithoutResourceName = withPlatform {
    nixk3s.appPlatform.gpuResourceName = lib.mkForce null;
    nixk3s.apps.example-gpu = goodApp // { gpu = true; };
  };

  # `root` is the sentinel an app uses to say its image must start as uid 0.
  # A registry entry of that name would turn the statement into an ordinary
  # lookup, and the exception would stop being countable.
  identitiesShadowingRoot = withPlatform {
    nixk3s.appPlatform.identities.root = { uid = 0; gid = 0; };
    nixk3s.apps.example-control = goodApp;
  };
in
lib.throwIf (brokenControls != [ ])
  ("nixk3s.apps fail-closed check is broken: these control apps do not render, so every negative case "
    + "below proves nothing: " + lib.concatStringsSep ", " brokenControls)
  (lib.throwIf (wronglyRendered != [ ])
    ("nixk3s.apps rendered declarations it must have refused: "
      + lib.concatStringsSep ", " wronglyRendered)
    (lib.throwIf (silentlyRefused != [ ])
      ("nixk3s.apps refused these without an assertion message, so something other than its own guards "
        + "stopped them — a typo in the case, or a neighbouring guard firing first: "
        + lib.concatStringsSep ", " silentlyRefused)
      (lib.throwIf gpuWithoutResourceName
        "nixk3s.apps rendered a GPU app while `appPlatform.gpuResourceName` was unset; the pod would schedule with no device and no error."
        (lib.throwIf identitiesShadowingRoot
          ("nixk3s.apps rendered while `appPlatform.identities` defined a role called `root`. That name is "
            + "the sentinel an app uses to say its image must start as uid 0; shadowing it turns the "
            + "statement into an ordinary lookup and the exception stops being countable.")
          (pkgs.writeText "nixk3s-apps-fail-closed" ''
            the controls render:
            ${lib.concatMapStringsSep "\n" (n: "  renders: ${n}") (lib.attrNames controls)}

            and every guard fires, with a message of its own:
            ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames assertionCases)}
              refused: gpu-without-a-named-device-resource
              refused: identity-registry-shadowing-the-root-sentinel

            and every option some render site reads on only one side of a branch
            is FORCED, so its type is checked whichever branch is taken:
            ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames illTypedCases)}
          '')))))
