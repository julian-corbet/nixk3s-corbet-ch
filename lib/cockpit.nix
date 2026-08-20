#
# The cockpit catalogue: what the platform's own faces ARE.
#
# WHAT BELONGS HERE, and it is a narrow test rather than a taste. A face is something you open to
# find out whether the platform is working — the GitOps controller that syncs the tree, the console
# you look at objects through, the portal that is the front door to those surfaces. The test:
#
#   A face belongs here only if it would still be worth running on a cluster with no apps in it.
#
# That is the whole reason a repository whose charter is "the mechanism, and no taxonomy of
# applications" may keep a catalogue at all. Nothing in this file is an app anybody HAS. Delete
# every workload on the cluster and this file is unchanged and still has a job; a catalogue of
# "apps you have" is empty on that same cluster, which is exactly the difference.
#
# WHAT IS KNOWLEDGE AND WHAT IS A VALUE. Everything here is true of the software wherever anyone
# runs it: the port it listens on, the directories it writes, which of them must already hold data,
# which variables name a path inside its own container, how patient a probe has to be, what its
# entrypoint does before it drops privileges. Nothing here names an address, a node, a hostname, a
# namespace, a uid or a secret's contents — those are one deployment's facts and they arrive from
# the consumer. The split is enforced rather than trusted: `state` here is the path INSIDE the
# container, and only a declaration can say what backs it.
#
# ONE ENTRY, DELIBERATELY. Two more faces are owned by the same decision that produced this file
# and neither is catalogued: one of them is the spine itself, bootstrapped before any Application
# exists and declared through the app grammar nowhere yet, and the other is still written in the
# older per-resource shape, so there is nothing to translate. Room is left for both. Nothing about
# either is invented here, because a catalogue entry written from a guess is worse than a missing
# one: the missing entry is visible.
{}:
{
  faces = {
    homarr = {
      image = "ghcr.io/homarr-labs/homarr";

      # ONE PORT, serving the web UI and the API alike. There is no second listener to publish and
      # no admin port to keep off the front.
      ports.http = 7575;
      primaryPort = "http";

      # ONE DIRECTORY, and everything the face keeps is inside it: the SQLite database, the dump of
      # the redis it runs in-process, the user CA certificates its integrations trust, and the
      # fallback directory named by `CA_TS_FALLBACK_DIR` below. It creates each of them itself on
      # first start.
      #
      # `mustExist` is the sharp half. A backing that CREATES the directory when it is missing lets
      # this face come up healthy against nothing at all, and coming up healthy is precisely the
      # failure: it does not refuse to start, it initialises a fresh database.
      state.appdata = {
        path = "/appdata";
        mustExist = true;
        mustExistReason =
          "an empty directory is not a missing volume to this face -- it initialises a fresh "
          + "database in it and every dashboard that was in the old one is gone, with the pod "
          + "reporting healthy throughout";
      };

      # THE ENTRYPOINT STARTS AS UID 0 AND DROPS. It chowns its own application tree and the
      # directory above to the uid and gid it is given, then drops privileges through its own init.
      # Forcing a pod-level user takes the chown away from it and the container crash-loops on
      # "Operation not permitted", so the grammar's reserved word for "this image must start as
      # root" is the true statement here and it is not a declaration's to override.
      identity = "root";

      # WHICH uid it drops TO is a fleet fact, delivered through these two variables. The catalogue
      # knows the SPELLING; the numbers come from whoever owns the directory being chowned.
      dropsPrivilegesVia = { user = "PUID"; group = "PGID"; };

      # The other half of that shape, as a class rather than a number: the process may drop
      # privileges, it may never regain them.
      security.allowPrivilegeEscalation = false;

      # THE VARIABLES THAT ARE NOT A DEPLOYMENT'S TO SET. Every one of them either names a path
      # inside the container -- which is knowledge, and which must stay inside the directory a
      # declaration backs -- or states the shape this catalogue is describing at all: both
      # datastores run INSIDE this container. Point the database somewhere else and it lands on the
      # pod's own filesystem, which is discarded on exactly the restart a single-writer volume
      # guarantees; say the redis is external and the face is looking for a server no container in
      # this pod is.
      env = {
        DB_DRIVER = "better-sqlite3";
        DB_DIALECT = "sqlite";
        DB_URL = "/appdata/db/db.sqlite";
        REDIS_IS_EXTERNAL = "false";
        CA_TS_FALLBACK_DIR = "/appdata/tailscale";
      };

      # A VALUE THAT MUST NEVER CHANGE, IN A TREE THAT CHANGES EVERY RENDER. This is the key the
      # face encrypts stored integration credentials with, so the credentials already inside the
      # database are readable only by the deployment that keeps handing it the same one. It is
      # therefore required, and required to arrive by REFERENCE: a Secret is named, its content is
      # never carried, and nothing that renders it into a manifest is expressible.
      secretEnv = [ "SECRET_ENCRYPTION_KEY" ];

      # IT AUTHENTICATES PEOPLE, and which provider is one installation's business: an issuer, a
      # client id and a client secret identify somebody's identity provider and are not knowledge.
      # What is knowledge is the name of the variable that selects the provider at all, which is
      # what lets a surface exposed to the internet with nothing selected be noticed.
      authProviderEnv = "AUTH_PROVIDERS";

      # PATIENCE, MEASURED ON THE WORKLOAD THIS WAS EXTRACTED FROM. The startup probe owns the
      # cold-boot window -- node boot plus database migrations -- so readiness never has to be slack
      # enough to cover it and never flaps under host I/O load. Readiness gates the Service
      # endpoint, which is what makes a held request from a wake front arrive only once the HTTP
      # server actually answers.
      probes = {
        startup = { path = "/"; periodSeconds = 3; failureThreshold = 40; timeoutSeconds = 5; };
        readiness = { path = "/"; periodSeconds = 5; failureThreshold = 30; timeoutSeconds = 5; };

        # NO LIVENESS PROBE, and its absence is a decision rather than an omission: a slow migration
        # answering "/" late would restart the container mid-write against a single-writer database.
        # Startup plus readiness is the whole safe set here.
        liveness = null;
      };

      note = ''
        THE PORTAL: one page that is the front door to the platform's own surfaces, with tiles that
        reach the services around it and report what they say.

        IT IS ONE CONTAINER HOLDING BOTH ITS DATASTORES, and that single fact is why it fits an app
        grammar whose unit is one pod: an in-process redis and an embedded SQLite database, no
        sidecar, no second workload, no external server to point at. Most portals of this shape are
        a compose file with three services in it; this one is a Deployment.

        THE DATABASE IS THE CONSTRAINT, not the size. SQLite is single-writer, so two live copies
        are two writers on one file: it cannot roll, it cannot have a second replica, and it cannot
        share its directory. None of that follows from how much traffic it takes, and the grammar
        derives every bit of it from the fact that the directory is durable.

        IT MAY SLEEP, and how well is measured rather than assumed: the deployment this entry was
        extracted from idles it to zero and wakes it on a request in about five seconds. What it
        does NOT do while asleep is not something this file can claim from the outside -- a
        dashboard is polled by the browser tabs that are open on it, and whether any integration
        keeps a timer of its own has not been established here. So sleeping is declarable and it is
        not defaulted.

        DOCKER-INTEGRATION WIDGETS DO NOT WORK IN A CLUSTER. They read a docker socket, and there is
        no docker socket in a k3s pod. Every other widget reaches its service over the network and
        is unaffected. This is knowledge rather than a setting: nothing a declaration writes brings
        those widgets back.
      '';
    };
  };
}
