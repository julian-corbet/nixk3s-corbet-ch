# What a PRIVATE module looks like on top of the public app grammar — the first
# and preferred of the two ways out of the vocabulary.
#
# `nixk3s.apps` deliberately cannot express a pinned cluster address, a UID, or
# a pod-spec knob it has no term for. That is not a wall: everything it renders
# is an ordinary nixidy resource, so a module the consumer keeps private can
# define MORE fields on the very same objects, and the module system merges the
# two. The public declaration stays free of fleet facts; the fleet facts stay in
# the repository that owns them.
#
# It is also where a SLOT becomes an ADDRESS. The public side declares that this
# app holds one number inside its repository's band; what that number means —
# which prefix it hangs off, how many address spaces it appears in at once — is
# arithmetic only the fleet knows, so it happens here. The correspondence is the
# whole reason one registry can drive several planes, and it never needs to be
# published to work.
#
# Nothing here is real — the prefix is fictional, and the point is the
# mechanism, not the values.
{ config, ... }:
let
  # The one fleet fact this file adds to a number the public side already
  # declared. A real consumer has more than one of these, which is exactly why
  # the slot, not the address, is the thing that gets governed.
  clusterPrefix = "10.0.0";
  addressOf = app: "${clusterPrefix}.${toString config.nixk3s.apps.${app}.slot}";
in
{
  applications.example-web = {
    resources = {
      # A pinned ClusterIP: exactly the kind of number the public grammar
      # refuses, derived here from the slot the grammar does carry. The Service
      # is still the one the grammar rendered — same labels, same selector, same
      # ports; this adds one field to it.
      services.example-web.spec.clusterIP = addressOf "example-web";

      deployments.example-web.spec.template.spec = {
        # A pod-spec knob with no term in the grammar. Kubernetes injects
        # <SERVICE>_PORT variables for every Service in the namespace, which
        # collides with apps that define an identically named variable of their
        # own; turning the injection off is per-app knowledge nobody generalizes.
        enableServiceLinks = false;

        # An identity the private layer allocates and the public layer must
        # never carry.
        securityContext = {
          runAsUser = 3001;
          runAsGroup = 3001;
        };
      };
    };
  };
}
