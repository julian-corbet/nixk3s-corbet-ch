# nixk3s.tenancy — the Argo CD AppProject tenancy model.
#
# One nixidy Application renders every AppProject, plus any namespaces a project chooses
# to ANCHOR (see the `namespaces` option), at a low sync-wave, so the projects (and their
# anchored namespaces) exist before the workload Applications that reference them sync.
# This mirrors the production pattern this module was extracted from: a single "projects"
# render, sync-wave -2, ServerSideApply so it can adopt AppProjects (and Namespaces) that
# pre-existed under a different management mechanism.
#
# THE LESSON THIS MODULE ENCODES, twice over:
#
#  1. An Argo CD Application that targets a namespace not listed in its AppProject's
#     `destinations` does not get rejected quietly — it goes to `InvalidSpecError` and
#     refuses to sync at all, including for otherwise-healthy resources already in that
#     namespace. Every app's target namespace MUST appear in its project's
#     `destinationNamespaces` before (or in the same render wave as) the app's own
#     Application is created.
#
#  2. A namespace anchored here that holds live/stateful contents (or that something else
#     must land in before wave 0) MUST carry `Prune=false` (the `namespaces.<name>.protected`
#     option, on by default) — otherwise a manifest slip elsewhere in the rendered tree can
#     make Argo CD read the Namespace itself as no-longer-desired and cascade-delete it,
#     and everything inside it, instead of just the one resource that actually should have
#     gone away.
{ lib, config, ... }:
let
  cfg = config.nixk3s.tenancy;

  # NB: lib.generators.toYAML is lib.generators.toJSON under the hood, so
  # each AppProject below renders as single-line JSON — valid YAML, but a
  # poor git diff (whole document changes as one line instead of per-field
  # hunks). Revisit with typed nixidy resources or a real YAML printer once
  # this repo has a working eval harness to check the swap against.
  toYAML = lib.generators.toYAML { };

  whitelistEntryType = lib.types.submodule {
    options = {
      group = lib.mkOption {
        type = lib.types.str;
        description = "API group to allow (\"*\" for all groups).";
      };
      kind = lib.mkOption {
        type = lib.types.str;
        description = "Resource kind to allow (\"*\" for all kinds).";
      };
    };
  };

  # Permissive by default: */* group+kind, scoped only by destination
  # namespace. This is a deliberate choice carried over from the source
  # system (single-operator cluster) — the governance value it wants is the
  # NAMESPACE boundary and the tier organization, not fine-grained resource
  # gating, which mainly adds "project blocks an otherwise-fine sync" gotchas
  # without a matching security benefit in a single-operator setting. A
  # multi-tenant cluster with mutually distrusting tenants should tighten
  # this per project.
  defaultWhitelist = [{ group = "*"; kind = "*"; }];

  # A namespace this project ANCHORS — rendered as a real Namespace object inside the
  # same early-wave tenancy Application as the AppProjects, instead of being left to
  # whichever workload Application's own `createNamespace` happens to target it first. Use
  # this only where creation-ordering or protection actually matters (see `namespaces`
  # option doc below) — most namespaces need no anchor at all.
  namespaceType = lib.types.submodule {
    options = {
      protected = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Sets `argocd.argoproj.io/sync-options: Prune=false` on the generated Namespace
          object. Defaults to true, mirroring the source system: every namespace it ever
          anchored this way turned out to need the guard, because anchoring a namespace
          here (rather than via a workload app's own `createNamespace`) is itself usually a
          sign that something about it — live/stateful contents, or another resource that
          must land in it before wave 0 — makes an accidental delete-and-recreate
          expensive. THE LESSON: without Prune=false, a manifest slip (a renamed or
          removed resource somewhere in the rendered tree) can make Argo CD read the
          Namespace as no-longer-desired and cascade-delete it — and everything inside it
          — instead of just the one resource that actually should have gone away. Set to
          `false` only for a namespace you are confident is safe to let Argo recreate
          freely.
        '';
      };

      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra labels on the generated Namespace object.";
      };

      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Extra annotations on the generated Namespace object, merged in alongside the
          `Prune=false` sync-option (when `protected`) and the intra-app `syncWave` (when
          set). A key set here wins over those automatic ones if they collide.
        '';
      };

      syncWave = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional intra-Application `argocd.argoproj.io/sync-wave` for this Namespace,
          RELATIVE ONLY to the other resources inside the tenancy Application (this is a
          different wave scope from the module-level `syncWave`, which orders the whole
          Application in the app-of-apps). `null` (the default) stamps no annotation —
          being rendered in the same early-wave Application as the AppProjects is what
          orders anchored namespaces ahead of the wave-0 workload apps, exactly as the
          source system relies on. Set a value only if resources INSIDE this Application
          must be ordered against each other explicitly.
        '';
      };
    };
  };

  projectType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = ''
          Human-readable summary of what this tier is for. Shown in the
          Argo CD UI and worth keeping honest — it is the only place this
          model documents itself to someone clicking around the cluster.
        '';
      };

      destinationNamespaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Namespaces this project's Applications are allowed to deploy
          into (all on `destinationServer`). EMPTY by default — this is a
          fleet-specific value; a consumer fills it in per project as
          real workloads land. An app whose Application targets a
          namespace missing from here fails Argo CD's spec validation
          (`InvalidSpecError`), not a partial/degraded sync.
        '';
      };

      sourceRepos = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "*" ];
        description = "Git repos this project's Applications may source manifests from.";
      };

      clusterResourceWhitelist = lib.mkOption {
        type = lib.types.listOf whitelistEntryType;
        default = defaultWhitelist;
        description = "Cluster-scoped resource kinds this project's Applications may manage.";
      };

      namespaceResourceWhitelist = lib.mkOption {
        type = lib.types.listOf whitelistEntryType;
        default = defaultWhitelist;
        description = "Namespaced resource kinds this project's Applications may manage.";
      };

      namespaces = lib.mkOption {
        type = lib.types.attrsOf namespaceType;
        default = { };
        description = ''
          Namespaces this project ANCHORS as real Namespace objects, rendered inside the
          same early-wave tenancy Application as the AppProjects — so they exist before
          any wave-0 workload Application tries to create resources inside them. EMPTY by default: most namespaces need no entry here at all — they
          are perfectly well created by whichever workload Application first targets them
          via its own `createNamespace`. Only anchor one here when that default ordering
          isn't good enough, e.g.:

            - something else (a SealedSecret, a ConfigMap) must land in the namespace
              BEFORE the wave-0 workload app's first sync, or
            - the namespace should be protected (see `protected`) independent of, or
              before, whichever app(s) eventually target it.

          Namespace names must be unique across the whole `projects` attrset — two
          projects anchoring the same name is always a config bug and fails eval with the
          duplicate names listed.
        '';
      };
    };
  };

  mkAppProject = name: project: {
    apiVersion = "argoproj.io/v1alpha1";
    kind = "AppProject";
    metadata = {
      inherit name;
      namespace = cfg.argoNamespace;
      finalizers = [ "resources-finalizer.argocd.argoproj.io" ];
    };
    spec = {
      description = project.description;
      sourceRepos = project.sourceRepos;
      destinations = map
        (namespace: { inherit namespace; server = cfg.destinationServer; })
        project.destinationNamespaces;
      clusterResourceWhitelist = project.clusterResourceWhitelist;
      namespaceResourceWhitelist = project.namespaceResourceWhitelist;
    };
  };

  mkNamespace = name: ns:
    let
      anns =
        lib.optionalAttrs (ns.syncWave != null) { "argocd.argoproj.io/sync-wave" = ns.syncWave; }
        // lib.optionalAttrs ns.protected { "argocd.argoproj.io/sync-options" = "Prune=false"; }
        // ns.annotations;
    in
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = { inherit name; }
        // lib.optionalAttrs (anns != { }) { annotations = anns; }
        // lib.optionalAttrs (ns.labels != { }) { labels = ns.labels; };
    };

  # Every anchored namespace across every project, flattened to one attrset keyed by
  # namespace name. Duplicate anchors across projects are ALWAYS a config bug (the worst
  # case: one project anchors with protected=true, another with protected=false, and the
  # unguarded one silently wins — the exact cascade-delete hole `protected` exists to
  # close), so they fail eval loudly instead of last-writer-winning.
  anchoredNames = lib.concatMap (p: lib.attrNames p.namespaces) (lib.attrValues cfg.projects);
  duplicateNames = lib.filter (n: lib.count (x: x == n) anchoredNames > 1) (lib.unique anchoredNames);
  allNamespaces =
    if duplicateNames != [ ] then
      throw "nixk3s.tenancy: namespace(s) anchored by more than one project: ${lib.concatStringsSep ", " duplicateNames}"
    else
      lib.concatMapAttrs (_projectName: project: project.namespaces) cfg.projects;
in
{
  options.nixk3s.tenancy = {
    enable = lib.mkEnableOption "the Argo CD AppProject tenancy model";

    argoNamespace = lib.mkOption {
      type = lib.types.str;
      default = "argocd";
      description = "Namespace Argo CD itself (and its AppProject CRs) lives in.";
    };

    destinationServer = lib.mkOption {
      type = lib.types.str;
      default = "https://kubernetes.default.svc";
      description = ''
        Cluster API endpoint used as the `server` field on every generated
        destination entry. The in-cluster default is correct for a
        single-cluster setup; override for a hub-of-clusters layout.
      '';
    };

    appName = lib.mkOption {
      type = lib.types.str;
      default = "projects";
      description = ''
        Name of the nixidy Application that carries the rendered AppProjects (and any
        anchored Namespaces). It intentionally belongs to Argo CD's built-in `default`
        project rather than one of `projects` — an Application cannot belong to a project
        it itself creates. Override to adopt an EXISTING application's name so migrating a
        production project layer onto this module becomes an in-place spec update (no
        prune/recreate race) instead of a delete-and-recreate across two applications —
        the same pattern the sibling `nixllm.serving` module uses for its own `appName`.
      '';
    };

    syncWave = lib.mkOption {
      type = lib.types.str;
      default = "-2";
      description = ''
        `argocd.argoproj.io/sync-wave` on the projects Application. Must
        sync (and go Healthy) before any wave-0 workload Application that
        references one of these projects, or that app's very first sync
        finds no matching AppProject yet.
      '';
    };

    projects = lib.mkOption {
      description = ''
        The tenancy model: one AppProject per attrset key. The module ships a
        three-tier model as CONFIG-SIDE defaults (see the config block): attrsOf
        definitions merge attr-by-attr across modules, so your definitions EXTEND the
        three tiers (add a project = add an attr) and override a tier's field by simply
        redefining it — the shipped descriptions are `lib.mkDefault`. Every
        `destinationNamespaces` list ships EMPTY (fleet-specific values a consumer
        supplies). The three tiers are always present while the module is enabled;
        replace the whole model with `lib.mkForce` if you genuinely want them gone.

        Sorting rule for GPU-era (or any scarce-shared-hardware) apps,
        carried over from the source system this model was extracted
        from:

          - manages the card/hardware itself (device plugin, scheduler,
            priority classes)                          -> management
          - burns it directly (holds a pod that consumes the hardware,
            or fronts it as the shared serving tier)    -> advanced
          - only calls a shared service that in turn uses the hardware,
            over HTTP/gRPC, never scheduling onto it    -> apps
      '';
      type = lib.types.attrsOf projectType;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    # The three-tier default model lives CONFIG-side (each field mkDefault), not in the
    # option default: an option default is discarded wholesale by the consumer's first
    # definition of `projects`, while config-side definitions merge attr-by-attr — the
    # exact trap the sibling nixgpu priority-ladder module hit and fixed the same way.
    nixk3s.tenancy.projects = {
      management.description = lib.mkDefault "Cluster/substrate management — the tier that manages the cluster and its shared hardware, and never consumes it as a tenant.";
      advanced.description = lib.mkDefault "Direct consumers of scarce shared hardware (e.g. GPU-holding pods) and the serving tier that fronts it for everyone else.";
      apps.description = lib.mkDefault "Everything else, including apps that only consume shared hardware indirectly via a service call.";
    };

    applications.${cfg.appName} = {
      namespace = cfg.argoNamespace;
      createNamespace = false; # argocd's own namespace already exists
      project = "default"; # bootstrap: this app can't belong to a project it creates
      annotations = {
        "argocd.argoproj.io/sync-wave" = cfg.syncWave;
        "argocd.argoproj.io/compare-options" = "ServerSideDiff=true";
      };
      syncPolicy.syncOptions.serverSideApply = true;
      yamls =
        (lib.mapAttrsToList (name: project: toYAML (mkAppProject name project)) cfg.projects)
        ++ (lib.mapAttrsToList (name: ns: toYAML (mkNamespace name ns)) allNamespaces);
    };
  };
}
