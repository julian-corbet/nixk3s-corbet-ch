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
  };

  # Three apps, chosen to cover the paths that differ in what gets RENDERED, not
  # merely in what evaluates: an always-on exposed app with probes and secrets,
  # a scale-to-zero GPU app on a claim that also uses the escape hatch, and a
  # portless worker on node-path state that owns its own namespace.
  nixk3s.apps = {
    # Always-on, publicly exposed, digest-pinned, both consumption modes of a
    # Secret, sized, and probed over HTTP.
    example-web = {
      namespace = "example-apps";
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
      image = "registry.example.com/example-org/example-worker:0.3.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
      command = [ "/bin/example-worker" ];
      args = [ "--queue" "example" ];
      # The path is a parameter, exactly like `namespace`: a real consumer
      # passes its own in from a private module. This one is a placeholder.
      state.spool = { hostPath = "/example/spool/example-worker"; mountPath = "/var/spool/example"; };
      # A Secret consumed as files rather than environment.
      secrets.credentials = { secret = "example-worker-credentials"; mountPath = "/run/credentials"; };
    };
  };
}
