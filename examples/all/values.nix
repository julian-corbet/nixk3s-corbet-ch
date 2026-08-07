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

  # The GPU app below needs a device, and the grammar refuses to guess what this
  # cluster calls one — so the example names it, generically.
  nixk3s.appPlatform.gpuResourceName = "example.com/gpu";

  # Three apps, chosen to cover the paths that differ in what gets RENDERED, not
  # merely in what evaluates: an always-on exposed app with a probe, a
  # scale-to-zero GPU app with state, and a portless worker that owns its own
  # namespace.
  nixk3s.apps = {
    # Always-on, publicly exposed, digest-pinned, with a readiness probe.
    example-web = {
      namespace = "example-apps";
      image = "registry.example.com/example-org/example-web:1.4.2@sha256:0000000000000000000000000000000000000000000000000000000000000000";
      ports.http.number = 8080;
      exposure = "public";
      replicas = 2;
      probe = { port = "http"; path = "/healthz"; };
      # A container-local bind address: allowed on purpose. The address guard
      # rejects fleet addresses, not the fact that a server binds to any
      # interface inside its own container.
      env.EXAMPLE_BIND_ADDRESS = "0.0.0.0";
    };

    # Scale-to-zero, needs the GPU (so the wake front resolves to sablier
    # without being named), and mounts an existing claim BY NAME.
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
      state.config = { claim = "example-canvas-config"; mountPath = "/config"; };
    };

    # No ports at all: renders a Deployment and no Service. Creates its own
    # namespace, which is therefore stamped Prune=false.
    example-worker = {
      namespace = "example-worker";
      createNamespace = true;
      image = "registry.example.com/example-org/example-worker:0.3.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
      command = [ "/bin/example-worker" ];
      args = [ "--queue" "example" ];
    };
  };
}
