# nixk3s.tenancy — the Argo CD AppProject tenancy model.
#
# One nixidy Application renders every AppProject (plus, optionally, whatever
# else a consumer chooses to fold into the same render) at a low sync-wave, so
# the projects exist before the workload Applications that reference them
# sync. This mirrors the production pattern this module was extracted from:
# a single "projects" render, sync-wave -2, ServerSideApply so it can adopt
# AppProjects that pre-existed under a different management mechanism.
#
# THE LESSON THIS MODULE ENCODES: an Argo CD Application that targets a
# namespace not listed in its AppProject's `destinations` does not get
# rejected quietly — it goes to `InvalidSpecError` and refuses to sync at
# all, including for otherwise-healthy resources already in that namespace.
# Every app's target namespace MUST appear in its project's
# `destinationNamespaces` before (or in the same render wave as) the app's
# own Application is created.
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

    applicationName = lib.mkOption {
      type = lib.types.str;
      default = "projects";
      description = ''
        Name of the nixidy Application that carries the rendered
        AppProjects. It intentionally belongs to Argo CD's built-in
        `default` project rather than one of `projects` — an Application
        cannot belong to a project it itself creates.
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
        The tenancy model: one AppProject per attrset key. The default
        ships a three-tier model, GENERICIZED and with every
        `destinationNamespaces` list EMPTY (those are fleet-specific
        values a consumer supplies). Add, rename, or remove tiers freely —
        this is a plain attrsOf, not a fixed enum.

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
      default = {
        management = {
          description = "Cluster/substrate management — the tier that manages the cluster and its shared hardware, and never consumes it as a tenant.";
        };
        advanced = {
          description = "Direct consumers of scarce shared hardware (e.g. GPU-holding pods) and the serving tier that fronts it for everyone else.";
        };
        apps = {
          description = "Everything else, including apps that only consume shared hardware indirectly via a service call.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    applications.${cfg.applicationName} = {
      namespace = cfg.argoNamespace;
      createNamespace = false; # argocd's own namespace already exists
      project = "default"; # bootstrap: this app can't belong to a project it creates
      annotations = {
        "argocd.argoproj.io/sync-wave" = cfg.syncWave;
        "argocd.argoproj.io/compare-options" = "ServerSideDiff=true";
      };
      syncPolicy.syncOptions.serverSideApply = true;
      yamls = lib.mapAttrsToList (name: project: toYAML (mkAppProject name project)) cfg.projects;
    };
  };
}
