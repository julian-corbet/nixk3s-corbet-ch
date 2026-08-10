# Placeholder values for every nixidy module in this repository — the file that
# makes the render check real. `nix flake check` renders the tenancy model from
# here, so a module that stops evaluating, or that grows a required value nobody
# supplies, fails in CI rather than in somebody's cluster.
#
# Nothing here is real: namespaces and repository URLs are generic, and no
# credential appears in any form.
#
# `nixk3s.tenancy` has NO required options at all — `enable = true` renders the
# three-tier model on its own. Everything below is here to exercise the parts
# of the module that would otherwise stay empty, because a check that renders
# an empty shell proves nothing about the shell's contents.
{
  # Required by the nixidy environment itself, not by the module.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixk3s.tenancy = {
    enable = true;

    projects = {
      # The three tiers the module ships. Their descriptions come from the
      # module; only the operator-specific parts are supplied here.
      #
      # `destinationNamespaces` ships empty on purpose — an Application whose
      # target namespace is missing from its project's list fails Argo CD's spec
      # validation, so this is the one thing a consumer must get right, and the
      # module refuses to guess it.
      management.destinationNamespaces = [ "argocd" "example-platform" ];
      advanced.destinationNamespaces = [ "example-gpu" ];
      # Every namespace the apps below land in appears here, because that is the
      # interlock: an app whose namespace is missing from its project's list
      # fails eval in this repository instead of failing to sync in a cluster.
      apps.destinationNamespaces = [ "example-apps" "example-worker" ];

      # A fourth project, added purely to prove the model EXTENDS rather than
      # being replaced: attrsOf definitions merge attr-by-attr, so adding a
      # project is adding an attribute and the three tiers stay intact.
      example-tenant = {
        description = "A fourth tier added by the consumer, proving the shipped model extends.";
        destinationNamespaces = [ "example-tenant" ];
        sourceRepos = [ "https://example.com/example-org/example-gitops.git" ];

        # Anchor one namespace as a real object, so the render exercises that
        # path too. Most namespaces need no entry here — whichever Application
        # first targets one creates it — so this is deliberately the exception.
        namespaces.example-tenant = { };
      };
    };
  };

  # Two cluster facts the grammar refuses to guess: what this cluster calls a
  # GPU, and which node holds the directories that node-path state lives on.
  # Both are set once, here, instead of in every app.
  nixk3s.appPlatform = {
    gpuResourceName = "example.com/gpu";
    hostPathNodeSelector = { "kubernetes.io/hostname" = "example-node"; };

    # The identity registry: role name -> what that role IS, numerically. An app
    # names a role; these numbers are the shape of somebody's /etc/passwd and
    # live here, once, exactly like the node selector above. Both roles are
    # invented for the check.
    identities = {
      example-portal = { uid = 4242; gid = 4242; };
      example-relay = { uid = 4343; gid = 4343; };
    };
  };

  # The band model, with the layout a consumer would supply. EVERY value here is
  # invented for the check: the module ships no band, no base, no binding and no
  # fallback, because which category owns which run of the number space — and
  # which repository owns which category — is the shape of somebody's fleet.
  nixk3s.addressing = {
    enable = true;

    bands = {
      example-alpha = {
        base = 32;
        description = "one category of thing";
      };
      example-beta = {
        base = 48;
        description = "another, and the one to take when neither obviously fits";
      };
    };

    # Which repository owns which category. Two origins, so the render exercises
    # a band with apps in it and a band with none.
    bindings = {
      example-repo-one = "example-alpha";
      example-repo-two = "example-beta";
    };

    # Named, never applied: an unbound origin still fails eval, and this only
    # lets the error say what to do about it.
    fallbackBand = "example-beta";
  };

  # Five apps, chosen to cover the paths that differ in what gets RENDERED, not
  # merely in what evaluates: an always-on exposed app with probes and secrets,
  # a scale-to-zero GPU app on a claim that also uses the escape hatch, a
  # portless worker on node-path state that owns its own namespace, a
  # multi-container app whose Service reaches a companion rather than the app's
  # own container, and an app with ports that publishes none of them.
  nixk3s.apps = {
    # Always-on, publicly exposed, digest-pinned, both consumption modes of a
    # Secret, sized, and probed over HTTP.
    example-web = {
      namespace = "example-apps";
      # WHO declared this app, and WHERE its identity sits. The origin is the
      # declaring repository naming itself; the slot is a fleet fact a private
      # consumer passes in, exactly like a node path. Nothing is rendered from
      # it — the private layer reads it to pin an address (see
      # examples/all/private-overlay.nix).
      origin = "example-repo-one";
      slot = 33;
      image = "registry.example.com/example-org/example-web:1.4.2@sha256:0000000000000000000000000000000000000000000000000000000000000000";
      ports.http.number = 8080;
      exposure = "public";
      replicas = 2;
      probes.readiness = { port = "http"; path = "/healthz"; initialDelaySeconds = 10; };
      probes.liveness = { port = "http"; path = "/healthz"; periodSeconds = 30; failureThreshold = 6; };
      resources.requests = { cpu = "50m"; memory = "64Mi"; };
      resources.limits = { memory = "256Mi"; };
      # Two Secrets, consumed the two different ways. Neither the values nor
      # where they come from are the app's business — only the names.
      secrets.credentials.env = {
        EXAMPLE_DB_PASSWORD = "db-password";
        EXAMPLE_SESSION_KEY = "session-key";
      };
      secrets.oidc = { secret = "example-web-oidc"; envFrom = true; };
      # A container-local bind address: allowed on purpose. The address guard
      # rejects fleet addresses, not the fact that a server binds to any
      # interface inside its own container.
      env.EXAMPLE_BIND_ADDRESS = "0.0.0.0";
    };

    # Scale-to-zero, needs the GPU (so the wake front resolves to sablier
    # without being named), mounts an existing claim BY NAME, is adopted in
    # place, and carries one object the grammar has no term for.
    example-canvas = {
      namespace = "example-gpu";
      project = "advanced";
      # Same repository, so the same band — a different project and a different
      # namespace change nothing about that: tenancy sorts by what a thing does,
      # the band model sorts by who declares it.
      origin = "example-repo-one";
      slot = 34;
      # Deliberately tag-only, so the render check sees the unpinned-image
      # warning fire as well as the pinned path above.
      image = "registry.example.com/example-org/example-canvas:2026.8";
      ports.http.number = 8188;
      exposure = "nb";
      scaling = "scale-to-zero";
      gpu = true;
      adopt = true;
      state.config = { claim = "example-canvas-config"; mountPath = "/config"; };
      # THE ESCAPE HATCH, used as intended: a whole object with no term in this
      # vocabulary, passed through verbatim. It warns, and the app's name shows
      # up in `appPlatform.rawEscapeHatchApps` so the count is visible.
      raw = [
        ''
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: example-canvas-extra
            namespace: example-gpu
          data:
            example.conf: |
              # an object this grammar has no term for
        ''
      ];
    };

    # No ports at all: renders a Deployment and no Service. Creates its own
    # namespace, which is therefore stamped Prune=false. Its state is a
    # directory on a node, which pins it there — the rendered objects say so.
    example-worker = {
      namespace = "example-worker";
      createNamespace = true;
      # A different repository, hence a different band — and no slot at all:
      # this app renders no Service, so there is no in-cluster address to name
      # and nothing asks it for one. Its origin still binds a band, because
      # every origin must.
      origin = "example-repo-two";
      image = "registry.example.com/example-org/example-worker:0.3.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
      command = [ "/bin/example-worker" ];
      args = [ "--queue" "example" ];
      # The path is a parameter, exactly like `namespace`: a real consumer
      # passes its own in from a private module. This one is a placeholder.
      state.spool = { hostPath = "/example/spool/example-worker"; mountPath = "/var/spool/example"; };
      # A Secret consumed as files rather than environment.
      secrets.credentials = { secret = "example-worker-credentials"; mountPath = "/run/credentials"; };
    };

    # ONE POD, FOUR CONTAINERS. The app's own process listens on a socket
    # nothing outside the pod may reach; a web front beside it holds the port
    # the Service publishes; and two init containers run to completion first, IN
    # THE ORDER WRITTEN — which is deliberately not the alphabetical one, since
    # reproducing that order is the whole reason `init` is a list.
    #
    # It also carries four of the five volume backings and both halves of the
    # identity split: the app names a ROLE, and the numbers come from
    # `appPlatform.identities` above.
    example-portal = {
      namespace = "example-apps";
      origin = "example-repo-one";
      slot = 35;
      image = "registry.example.com/example-org/example-portal:3.1.0@sha256:4444444444444444444444444444444444444444444444444444444444444444";
      exposure = "public";

      # REAL, and deliberately unpublished: the front talks to it over
      # loopback. Dropping it from `ports` would be a lie about the container;
      # publishing it would be an address the app never asked for.
      ports.app = { number = 9000; publish = false; };

      identity = "example-portal";
      security = {
        runAsNonRoot = true;
        seccomp = "RuntimeDefault";
        allowPrivilegeEscalation = false;
        capabilitiesDrop = [ "ALL" ];
      };
      resources.requests = { cpu = "50m"; memory = "128Mi"; };

      # One curated directory, two views of it — and the one volume in this
      # render whose files the kubelet is allowed to take ownership of.
      state.html = {
        hostPath = "/example/spool/example-portal";
        ownership = "kubelet";
        mounts = [
          { mountPath = "/var/www/html"; }
          { mountPath = "/var/www/config"; subPath = "config"; readOnly = true; }
        ];
      };

      # A volume with NO view on the app's own container: only the front reads
      # it. Legal for the first time, and the reason a `state` entry may give
      # neither `mountPath` nor `mounts`.
      state.web-conf.configMap = "example-portal-web";

      # A Secret as a VOLUME rather than as environment, projecting ONE key onto
      # one exact filename — which is what `secrets.<n>.mountPath` cannot say,
      # because it mounts the whole Secret as a directory.
      state.cfg-secret = {
        secret = "example-portal-secrets";
        items."zzz-secrets.conf" = "zzz-secrets.conf";
        mounts = [{
          mountPath = "/etc/portal/conf.d/zzz-secrets.conf";
          subPath = "zzz-secrets.conf";
          readOnly = true;
        }];
      };

      # A path the image insists on writing to and nobody keeps. It is not
      # durable, so it does not force `Recreate` on its own.
      state.scratch = { emptyDir = true; mountPath = "/tmp/portal"; };

      # The default is the narrow one: these credentials reach the app's own
      # container and nothing else in the pod.
      secrets.credentials.env.EXAMPLE_DB_PASSWORD = "db-password";

      # ... and this one goes the other way, to the front only. The app's own
      # process never sees it.
      secrets.front-token = {
        secret = "example-portal-front-token";
        env.EXAMPLE_FRONT_TOKEN = "token";
        containers = [ "web" ];
      };

      companions.web = {
        image = "registry.example.com/example-org/example-front:1.27.0@sha256:5555555555555555555555555555555555555555555555555555555555555555";
        # The port the Service publishes, on the container that actually holds
        # it — reached by NAME, which Kubernetes resolves pod-wide, so nothing
        # about the Service's selector changes.
        ports.http = { number = 8080; servicePort = 80; };
        mounts.html = [{ mountPath = "/var/www/html"; readOnly = true; }];
        mounts.web-conf = [{ mountPath = "/etc/front/front.conf"; subPath = "front.conf"; readOnly = true; }];
        probes.readiness = { port = "http"; path = "/healthz"; };
        resources = { requests = { cpu = "10m"; memory = "32Mi"; }; limits.memory = "256Mi"; };
        security.allowPrivilegeEscalation = false;
      };

      init = [
        {
          name = "prepare-tree";
          image = "registry.example.com/example-org/example-portal:3.1.0@sha256:4444444444444444444444444444444444444444444444444444444444444444";
          command = [ "sh" "-c" ];
          args = [ "mkdir -p /var/www/html/data" ];
          mounts.html = [{ mountPath = "/var/www/html"; }];
        }
        {
          # A REFUSAL, not a wait: the app must not start and regenerate its
          # own crypto identity when the Secret has not arrived.
          name = "assert-secrets";
          image = "registry.example.com/example-org/example-portal:3.1.0@sha256:4444444444444444444444444444444444444444444444444444444444444444";
          command = [ "sh" "-c" ];
          args = [ "test -s /etc/portal/conf.d/zzz-secrets.conf" ];
          mounts.cfg-secret = [{
            mountPath = "/etc/portal/conf.d/zzz-secrets.conf";
            subPath = "zzz-secrets.conf";
            readOnly = true;
          }];
        }
      ];
    };

    # PORTS, AND NO ADDRESS. It listens on a real socket that nothing outside
    # the pod should reach, so it renders no Service — exactly like an app with
    # no ports, and therefore nothing asks it for a slot.
    #
    # It also has no durable state and still cannot run two live copies, which
    # is what `singleWriter` says directly instead of leaving it to be inferred
    # from a volume that is not there.
    example-relay = {
      namespace = "example-apps";
      origin = "example-repo-two";
      image = "registry.example.com/example-org/example-relay:0.9.1@sha256:6666666666666666666666666666666666666666666666666666666666666666";
      ports.metrics = { number = 9100; publish = false; };
      singleWriter = true;
      probes.readiness.port = "metrics";
      # The other spelling of an identity: this image starts as root, chowns its
      # own config and drops privileges itself, so the numbers arrive as
      # ENVIRONMENT and no `runAsUser` is rendered. Same registry entry either
      # way — the app never restates a uid in order to change spelling.
      identity = "example-relay";
      identityEnv = { user = "EXAMPLE_UID"; group = "EXAMPLE_GID"; };
    };
  };
}
