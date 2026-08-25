#
# Two declarations against the awkward catalogue, written to make every half of the split visible
# in a rendered manifest.
#
# `one` supplies the declaration half of all four split fields: what backs the directory, this
# cluster's patience, which Secret delivers the credentials the catalogue named, and whether the
# hardening classes are stamped. `two` supplies almost nothing, because the interesting question
# about `two` is what the factory does when a catalogue is silent.
{ ... }:
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  # The fleet's identity registry: what a ROLE means in numbers here. A catalogue names a role and
  # never a number, and this is the only place the two meet.
  # What this site calls the device the grammar requests. Never guessed: a device request under a
  # name the cluster does not advertise is a pod that never schedules.
  nixk3s.appPlatform.gpuResourceName = "example.com/gpu";

  nixk3s.appPlatform.identities.example-role = {
    uid = 3001;
    gid = 3001;
  };

  nixconsumer.clusterPlatform = {
    namespace = "example-consumer";
    project = "example";
    # Left unset on purpose: `origin` is the fleet's, and the factory warns rather than guesses.
    # The render check reads the absence of any address back off the objects.
  };

  nixconsumer.applications = {
    # Keeps nothing the grammar can see, and must still never run twice. The only thing standing
    # between this and a rolling update is the catalogue's own word.
    lock = {
      app = "epsilon";
      version = "2.1.0";
      exposure = "internal";
    };

    one = {
      app = "alpha";
      version = "1.4.2";
      createNamespace = true;
      exposure = "nb";
      slot = 40;

      # The backing half. The catalogue said WHERE (/var/lib/alpha); this says WHAT HOLDS IT.
      state.data = {
        hostPath = "/example/state/one";
        hostPathType = "DirectoryOrCreate";
      };
      # The growing tree, on a path somebody curates outside the cluster. Its ownership is left at
      # `site-curated`, which is the answer the catalogue's `grows` makes the only legal one.
      state.data-archive.hostPath = "/example/archive/one";

      # The budget half. The catalogue's own periodSeconds and timeoutSeconds survive; only the
      # number stated here changes, which is what "unstated is the catalogue's" has to mean.
      probes.readiness.failureThreshold = 30;

      # The delivery half. The catalogue named the VARIABLE; this names the Secret and renames the
      # key inside it. Nothing here is a value.
      credentials = {
        secret = "example-one-credentials";
        keys.ALPHA_TOKEN = "token";
        # The other half of the same variable: this one is NOT in this workload's own Secret, and
        # forcing it in there would mean copying somebody else's credential to a second place.
        secrets.ALPHA_SMTP_PASSWORD = "example-shared-mail";
      };

      # WHERE the service it needs actually is, and what it should call itself. The catalogue named
      # both variables; neither URL could have been written there.
      requires.index.endpoint = "http://example-index:9200";
      publicUrl = "https://example.com";

      env.ALPHA_MODE = "declared"; # merged OVER the catalogue's, so the render shows this one
      args = [ "--verbose" ];

      resources = {
        cpuRequest = "10m";
        memoryRequest = "32Mi";
        memoryLimit = "256Mi";
      };
    };

    two = {
      app = "beta";
      version = "0.9.0";
      exposure = "internal";

      # A claim rather than a node path, so the render covers the other backing. The catalogue's
      # own readOnly is NOT restated here -- the check proves it reaches the mount anyway.
      state.reference.claim = "example-reference";

      # A ROLE, resolved against the platform's identity registry below.
      identity = "example-role";

      # The live objects call this one something else. A rename is a delete and a create, never an
      # edit, so adopting a cluster's history means saying what it already calls things.
      objectName = "example-beta-renamed";

      # Stateless, and the catalogue does not call it a single writer, so more than one is legal.
      replicas = 2;

      # `harden` is left at its default with a catalogue that states no hardening classes. The
      # question this answers is whether that renders nothing or throws.
    };
  };
}
