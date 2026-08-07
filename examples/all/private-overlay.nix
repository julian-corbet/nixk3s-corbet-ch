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
# Nothing here is real — the address is fictional, and the point is the
# mechanism, not the values.
{
  applications.example-web = {
    resources = {
      # A pinned ClusterIP: exactly the kind of number the public grammar
      # refuses, set here without touching the app declaration. The Service is
      # still the one the grammar rendered — same labels, same selector, same
      # ports; this adds one field to it.
      services.example-web.spec.clusterIP = "10.0.0.9";

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
