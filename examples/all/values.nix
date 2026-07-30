# Placeholder values for every nixidy module in this repository — the file that
# makes the render check real. `nix flake check` renders the tenancy model from
# here, so a module that stops evaluating, or that grows a required value nobody
# supplies, fails in CI rather than in somebody's cluster.
#
# Nothing here is real: namespaces and repository URLs are generic, and no
# credential appears in any form.
#
# Note that `nixk3s.tenancy` has NO required options at all — `enable = true`
# renders the three-tier model on its own. Everything below is here to exercise
# the parts of the module that would otherwise stay empty, because a check that
# renders an empty shell proves nothing about the shell's contents.
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
      apps.destinationNamespaces = [ "example-apps" ];

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
}
