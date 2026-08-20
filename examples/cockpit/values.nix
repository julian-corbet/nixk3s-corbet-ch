# Placeholder values for the cockpit module — the file that makes its checks real. `nix flake
# check` renders the whole surface from here, so a module that stops evaluating, or that grows a
# required value nobody supplies, fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, band, path, name, number and image is invented for this
# file, and no credential appears in any form — only the NAME of a Secret that would hold one, and
# the NAME of the key inside it.
#
# TWO DECLARATIONS OF ONE FACE, which is the honest shape while the catalogue holds one entry: a
# rendered surface exercising every path the module has (durable state that must already exist, an
# identity the image drops to, a Secret consumed by key, a position in a band, sleeping behind a
# wake front), and a parked one proving a declaration can exist without rendering — the difference
# the render check reads back off the tree.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  # The one cluster fact the grammar refuses to guess for node-path state: which node holds the
  # directory. Set once here instead of in the declaration, exactly as a real consumer would.
  nixk3s.appPlatform.hostPathNodeSelector = { "kubernetes.io/hostname" = "example-node"; };

  # The band model, with the layout a consumer supplies. The cockpit hands it an origin and a slot;
  # which band that origin binds, and where the band sits in the number space, is fleet layout and
  # is invented here for the check.
  nixk3s.addressing = {
    enable = true;
    bands.example-platform = {
      base = 32;
      description = "the platform's own faces";
    };
    bindings.nixk3s = "example-platform";
    fallbackBand = "example-platform";
  };

  nixk3s.cockpit.surfaces = {
    # The rendered one. It anchors its own namespace, holds a position in the band above, sleeps
    # behind a wake front, backs the one directory the catalogue says it writes with a node path
    # that must ALREADY EXIST, and takes the key that must never change from a named Secret.
    example-portal = {
      face = "homarr";
      version = "0.0.0";
      # A whole reference, so two syncs of an identical rendered tree run identical code.
      image = "registry.example.com/example-org/example-portal:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
      namespace = "example-cockpit";
      createNamespace = true;
      project = "example-management";
      exposure = "public";
      slot = 33;
      scaling = "scale-to-zero";
      wake = "keda";
      adopt = true;

      # The identity the image's root entrypoint drops to. Invented numbers: on a real fleet these
      # are the ownership of the directory below, and they come from wherever that is decided.
      posixIdentity = { uid = 4242; gid = 4242; };

      # WHAT BACKS the directory — the half the catalogue cannot supply. `Directory` is the default
      # and is not restated: the catalogue marks this one as having to hold data already, so the
      # creating backing is refused rather than defaulted away.
      state.appdata.hostPath = "/example/state/example-portal";

      # Two keys out of one Secret, by name. The values never pass through Nix.
      secrets.example-portal-secrets.env = {
        SECRET_ENCRYPTION_KEY = "encryption-key";
        EXAMPLE_OIDC_CLIENT_SECRET = "oidc-client-secret";
      };

      # One deployment's own values, merged over the catalogue's. The provider selector is here
      # because a face reachable from the internet that authenticates nobody is warned about.
      env = {
        TZ = "UTC";
        AUTH_PROVIDERS = "oidc";
      };
    };

    # PARKED, not rendered: a declaration kept in the tree with `enable = false`. Its required
    # values are still required — parking a declaration does not make it half-written — and it
    # produces no Application, no Namespace and no slot claim, which is what the render check reads
    # back by counting what is in the tree.
    example-parked-portal = {
      enable = false;
      face = "homarr";
      version = "0.0.0";
      namespace = "example-parked-cockpit";
    };
  };
}
