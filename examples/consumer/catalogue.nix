#
# A catalogue that exists to be AWKWARD, on purpose.
#
# The consumer factory accepts two spellings for `ports` and two for `state`, and two ways of
# saying which probes a piece of software warrants. Those tolerances are not a convenience: they
# are why thirteen existing catalogues could move onto one translator without being rewritten to
# agree on punctuation. An untested tolerance is a claim, so this file writes each entry in the
# spelling the other one does not use, and nothing here is written the same way twice.
#
#   alpha   integer ports · string state · a `probes` attrset · hardening · credentials
#   beta    attrset ports · attrset state with a catalogue-side readOnly · per-kind
#           `readiness`/`liveness` fields · NO hardening · NO credentials · no env, no args
#
# `beta` is the more valuable of the two, because every field it omits is one the factory reads
# through an `or` default. A missing `hardening` that threw would have been found by nobody: no
# existing catalogue omits it, so no existing check renders an entry without one.
{ }:
{
  entries = {
    alpha = {
      image = "registry.example.com/example-org/alpha";
      ports.http = 8080;
      primaryPort = "http";

      # A mount path as a bare string, which is what most catalogues here write.
      state.data = "/var/lib/alpha";

      env.ALPHA_MODE = "catalogued";
      args = [ "--serve" ];

      # WHICH VARIABLES carry credentials. Never which Secret, and never a value.
      credentials = [ "ALPHA_TOKEN" ];

      # The `probes` attrset spelling: one key per probe, the shape underneath.
      probes = {
        readiness = {
          path = "/healthz";
          periodSeconds = 10;
          failureThreshold = 6;
          timeoutSeconds = 1;
        };
      };

      hardening = {
        capabilities = "none";
        privilegeEscalation = "never";
        seccomp = "RuntimeDefault";
        rootFilesystem = "read-only";
      };
    };

    beta = {
      image = "registry.example.com/example-org/beta";

      # The attrset spelling, carrying a field the integer form cannot express. It reaches the
      # rendered Service untouched, which is the point: normalising must not mean flattening.
      ports.api = { number = 9000; protocol = "TCP"; };
      primaryPort = "api";

      # The attrset spelling of a directory, with the half only a catalogue may state. THIS
      # SOFTWARE ONLY EVER READS IT -- that is knowledge, so it wins over a declaration that says
      # otherwise, and the render check reads it back off the volumeMount.
      state.reference = { mountPath = "/srv/reference"; readOnly = true; };

      # Per-kind probe fields rather than a `probes` attrset. Same fact, other spelling.
      readiness = {
        path = "/ready";
        periodSeconds = 5;
        failureThreshold = 12;
        timeoutSeconds = 2;
      };

      liveness = {
        path = "/alive";
        periodSeconds = 30;
        failureThreshold = 3;
        timeoutSeconds = 2;
      };

      # NO `env`, NO `args`, NO `credentials`, NO `hardening`. Every one of those is read through a
      # default in the factory, and a default nothing exercises is a default nobody has run.
    };
  };
}
