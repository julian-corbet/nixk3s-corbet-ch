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

      # A mount path as a bare string, which is what most catalogues here write. Kept in that
      # spelling deliberately: it is the only entry exercising it.
      # A SHORTLIST, because a scratch directory under this software's store is discarded on
      # exactly the restart the store exists to survive. Five backings exist; this one accepts two.
      state.data = {
        mountPath = "/var/lib/alpha";
        backings = [ "claim" "hostPath" ];
      };

      # A SECOND directory, in the other spelling, carrying the one fact only a catalogue can state
      # about a tree: that it GROWS. An archive, an upload tree, a media library -- something whose
      # whole purpose is to keep getting bigger, which is what makes a recursive chown on every pod
      # start the wrong idea rather than merely a slow one.
      state.data-archive = { mountPath = "/var/lib/alpha/archive"; grows = true; };

      env.ALPHA_MODE = "catalogued";
      args = [ "--serve" ];

      # WHICH VARIABLES carry credentials. Never which Secret, and never a value. Two of them, and
      # the second exists to be delivered from somewhere else: a catalogue cannot know that one of
      # these comes from a Secret another workload owns, so it says only that both are credentials.
      credentials = [ "ALPHA_TOKEN" "ALPHA_SMTP_PASSWORD" ];

      # The `probes` attrset spelling: one key per probe, the shape underneath.
      probes = {
        readiness = {
          path = "/healthz";
          periodSeconds = 10;
          failureThreshold = 6;
          timeoutSeconds = 1;
        };
      };

      # WHICH VARIABLE carries the endpoint of a service this one needs. Never the endpoint.
      requires.index = {
        env = "ALPHA_INDEX_URL";
        # WHAT IS SPOKEN on the other end. A queue reached over http and an index reached over
        # redis are both plausible strings and neither works; which one belongs here is a property
        # of the software, not of one cluster's routing.
        scheme = "http";
      };

      # WHICH VARIABLE this software reads its own public URL from, for the links it generates.
      selfUrlEnv = "ALPHA_PUBLIC_URL";

      # IT HAS WORK THAT HAPPENS WHILE NOBODY IS LOOKING, so idling it to zero does not make that
      # work late -- it makes it not happen. The factory refuses the combination rather than
      # warning about it.
      # STATED AT A VOLUME, AND IN ITS OWN WORDS. A bare `false` refuses; a catalogue that has
      # measured its own software and knows the loss is survivable says so, and gets to explain
      # why in a sentence somebody can act on.
      idleSafe = {
        safe = false;
        severity = "refuse";
        because = "The reminder it sends is the one nobody is waiting for.";
      };

      # WHAT ITS ENTRYPOINT NEEDS SAYING. Leaving it out starts this image with no subcommand,
      # which prints help and exits 0 -- a container that "ran".
      command = [ "alpha" "serve" ];

      # ONE PROCESS MAY HAVE THIS OPEN. Not a scaling preference: a second copy corrupts the
      # store rather than sharing the load.
      singleWriter = true;

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

      # WHICH VARIABLE this software reads its own uid from. The uid itself is never here: a role
      # is resolved against the consumer's identity registry, which is the only thing that knows
      # what a role means on a given fleet.
      # IT PUTS WORK ON A GRAPHICS DEVICE. A catalogue fact of exactly the same kind as idle
      # safety, and the grammar asks the site what its own device is called.
      gpu = true;

      # AND IT ASKS NOBODY FOR ANYTHING. Warned rather than refused here, because this one is
      # reached only from inside and the catalogue says so in its own words.
      authenticates = {
        authenticates = false;
        severity = "warn";
        because = "It is a rendering worker, reached by the queue rather than by a person.";
      };

      identityEnv = {
        user = "BETA_UID";
        group = "BETA_GID";
      };

      # NO `env`, NO `args`, NO `credentials`, NO `hardening`. Every one of those is read through a
      # default in the factory, and a default nothing exercises is a default nobody has run.
    };

    # A THIRD ENTRY, WRONG ON PURPOSE, and declared by nothing in the example values. Its nested
    # directories are keyed so the inner one sorts FIRST, which is a bug a catalogue can make and
    # no declaration can fix. It exists so the refusal has something to fire on: assertions only
    # run for declared workloads, so an entry nobody declares leaves the example green while the
    # eval check can declare it in one case and watch the guard bite.
    # A SINGLE WRITER THAT KEEPS NOTHING THE GRAMMAR CAN SEE. This entry exists because the other
    # single writer in this file also has a node path, and durable state forces Recreate on its
    # own -- so an assertion about `singleWriter` made against THAT one passes whether the term is
    # forwarded or not. That is not a hypothetical: one repository in this family declared
    # `singleWriter` on a workload with no state, the translator dropped it, and the only reason
    # nothing had broken was that its sibling happened to have a directory.
    #
    # Its store is somewhere the grammar cannot see -- a remote lock, a warm cache on a network
    # mount -- which is exactly when the catalogue has to say so, because nothing can infer it.
    epsilon = {
      image = "registry.example.com/example-org/epsilon";
      ports.http = 5500;
      primaryPort = "http";
      state = { };
      singleWriter = true;
    };

    # SOFTWARE NOBODY PUBLISHES A CONTAINER FOR. Upstream ships a build recipe; whoever runs it
    # brings their own image. Declared by nothing in the example values -- it exists so the
    # refusal has something to fire on.
    delta = {
      image = null;
      ports.http = 6000;
      primaryPort = "http";
      state = { };
    };

    gamma = {
      image = "registry.example.com/example-org/gamma";
      ports.http = 7000;
      primaryPort = "http";

      # `archive` sorts before `data`, and lives inside it. Rendered in that order the archive is
      # written first and `data` is laid on top of it.
      state = {
        archive = { mountPath = "/var/lib/gamma/archive"; };
        data = { mountPath = "/var/lib/gamma"; };
      };
    };
  };
}
