{ lib, mkConsumerModule }:

let
  catalogue = import ./multi-root-catalogue.nix { };

  planeNamespace = { entry, platform, ... }:
    if entry.plane == "execution"
    then platform.executionNamespace
    else platform.controlNamespace;

  kindOf = { entry, ... }: entry.delivery;

  roleCredentialType = lib.types.submodule {
    options = {
      secret = lib.mkOption {
        type = lib.types.str;
        description = "Existing Secret that holds this credential role.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = "Key inside the Secret that holds this credential role.";
      };
    };
  };

  # A consumer may already have a deliberately smaller public state vocabulary. Overlaying this
  # on the still-enabled common `state` term keeps the central renderer and guards while proving
  # they do not rely on the wider backing record merely being writable.
  narrowBackingType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      hostPathType = lib.mkOption {
        type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
        default = "Directory";
      };
    };
  };

  legacyResourceType = lib.types.submodule {
    options = {
      requests = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
      limits = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };
  };

  legacyStateType = lib.types.submodule {
    options = {
      secret = lib.mkOption { type = lib.types.str; };
      key = lib.mkOption { type = lib.types.str; };
      path = lib.mkOption { type = lib.types.str; };
      owner = lib.mkOption { type = lib.types.enum [ "site-curated" "kubelet" ]; };
      volumeName = lib.mkOption { type = lib.types.str; };
    };
  };

  roleSecretsOf = x:
    let
      roles = x.entry.credentials or { };
      known = lib.filterAttrs (role: _: roles ? ${role}) x.w.credentials;
    in
    lib.mapAttrs
      (role: value: {
        secret = value.secret;
        env.${roles.${role}.env} = value.key;
      })
      known;

  roleCredentialAssertions = contexts: lib.concatMap
    (x:
      let
        roles = x.entry.credentials or { };
        unknown = lib.subtractLists (lib.attrNames roles) (lib.attrNames x.w.credentials);
        missing = lib.attrNames (lib.filterAttrs
          (role: credential: credential.required && !(x.w.credentials ? ${role}))
          roles);
        isReference = lib.isString x.kind && x.kind == "reference";
      in [
        {
          assertion = unknown == [ ];
          message = "nixmulti: `${x.root}.${x.name}` names unknown credential roles: "
            + lib.concatStringsSep ", " unknown;
        }
        {
          assertion = missing == [ ];
          message = "nixmulti: `${x.root}.${x.name}` is missing required credential roles: "
            + lib.concatStringsSep ", " missing;
        }
        {
          assertion = !isReference || x.w.credentials == { };
          message = "nixmulti: `${x.root}.${x.name}` is a reference and may not name credentials";
        }
      ])
    contexts;

  legacyMountsOf = w: mounts: lib.mapAttrs'
    (key: value:
      lib.nameValuePair
        (if w.state ? ${key} then w.state.${key}.volumeName else key)
        value)
    mounts;

  legacyStateOf = w: lib.mapAttrs'
    (_key: value: lib.nameValuePair value.volumeName {
      secret = value.secret;
      ownership = value.owner;
      mounts = [{
        mountPath = value.path;
        subPath = value.key;
        readOnly = true;
      }];
    })
    w.state;

  extendLegacyWorker = { app, w, ... }: app // {
    state = legacyStateOf w;
    resources = w.resources;
    companions = lib.mapAttrs
      (name: companion: companion // {
        mounts = legacyMountsOf w companion.mounts;
        resources = w.companionResources.${name} or { requests = { }; limits = { }; };
      })
      (app.companions or { });
    init = map
      (container: container // { mounts = legacyMountsOf w container.mounts; })
      (app.init or [ ]);
  };

  legacyWorkerAssertions = contexts: lib.concatMap
    (x:
      let
        relative = lib.attrNames (lib.filterAttrs (_: value: !(lib.hasPrefix "/" value.path)) x.w.state);
      in [{
        assertion = relative == [ ];
        message = "nixmulti: `${x.root}.${x.name}` legacy state paths must be absolute: "
          + lib.concatMapStringsSep ", " (name: "`${name}`") relative;
      }])
    contexts;
in
{
  imports = [
    (mkConsumerModule {
      namespace = "nixmulti";

      extraPlatformOptions = {
        controlNamespace = lib.mkOption {
          type = lib.types.str;
          description = "Namespace for catalogue entries on the control plane.";
        };
        executionNamespace = lib.mkOption {
          type = lib.types.str;
          description = "Namespace for catalogue entries on the execution plane.";
        };
      };

      roots = {
        services = {
          catalogue = catalogue.services;
          selector = "service";
          kind = kindOf;
          # This mixed root uses role-shaped credentials. Removing the common term opts out of its
          # renderer and guards; extraOptions then deliberately redeclares the path below.
          disabledOptions = [ "namespace" "credentials" ];
          namespaceOf = planeNamespace;
          nameOf = { name, entry, w, ... }:
            if w.objectName != null then w.objectName else entry.renderName or name;
          # This root's chart adapter produces YAML separately from the ordinary declaration term.
          # Combining both proves `manifestsOf` is the authority used by rendering and guards.
          extraOptions.generatedManifests = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Opaque YAML produced by this root's external chart adapter.";
          };
          extraOptions.credentials = lib.mkOption {
            type = lib.types.attrsOf roleCredentialType;
            default = { };
            description = "Credential values keyed by the catalogue's semantic role.";
          };
          extraOptions.storageMode = lib.mkOption {
            type = lib.types.enum [ "ordinary" "archive" ];
            default = "ordinary";
            description = "Whether this declaration enables the catalogue's conditional archive.";
          };
          extraOptions.state = lib.mkOption {
            type = lib.types.attrsOf narrowBackingType;
            default = { };
            description = "The consumer's intentionally narrow claim-or-hostPath backing surface.";
          };
          manifestsOf = { w, ... }: w.manifests ++ w.generatedManifests;
          requiredStateKeys = { entry, ... }:
            entry.requiredStateKeys or (lib.attrNames (entry.state or { }));
          allowedStateKeys = { entry, w, ... }:
            lib.filter
              (key: key != (entry.archiveStateKey or null) || w.storageMode == "archive")
              (lib.attrNames (entry.state or { }));
          # These bogus identity values are deliberate fixture pressure: the factory must reapply
          # the resolver-owned fields after the extension has added its domain secrets.
          extend = x@{ app, ... }: app // {
            secrets = roleSecretsOf x;
            name = "extension-must-not-rename";
            namespace = "extension-must-not-move";
            project = "extension-must-not-retenant";
            createNamespace = false;
          };
          extendManifest = { application, ... }: application // {
            namespace = "extension-must-not-move";
            project = "extension-must-not-retenant";
            createNamespace = true;
            yamls = [ ''
              apiVersion: v1
              kind: ConfigMap
              metadata:
                name: extension-must-not-replace-yaml
            '' ];
            syncPolicy.syncOptions.serverSideApply = false;
            compareOptions.serverSideDiff = false;
          };
          assertions = roleCredentialAssertions;
          enableByDefault = { entry, ... }: entry.enabledByDefault or true;
          defaults = { entry, ... }: {
            exposure = entry.defaultExposure or "internal";
          };
        };

        workers = {
          catalogue = catalogue.workers;
          selector = "worker";
          kind = kindOf;
          # Execution-plane entries use a legacy declaration whose state and sizing records are
          # structurally incompatible with the shared shape. Removing those common terms transfers
          # their rendering, guards, and companion/init mount remapping to this root's adapter.
          disabledOptions = [
            "namespace"
            "exposure"
            "slot"
            "wake"
            "state"
            "resources"
            "companionResources"
          ];
          extraOptions.state = lib.mkOption {
            type = lib.types.attrsOf legacyStateType;
            default = { };
          };
          extraOptions.resources = lib.mkOption {
            type = legacyResourceType;
            default = { };
          };
          extraOptions.companionResources = lib.mkOption {
            type = lib.types.attrsOf legacyResourceType;
            default = { };
          };
          # An overlay may also refine an ENABLED common option. This keeps the shared image
          # renderer and guards, but narrows the nullable common version to a required string.
          extraOptions.version = lib.mkOption {
            type = lib.types.str;
            description = "Required build tag for this worker family.";
          };
          namespaceOf = planeNamespace;
          extend = extendLegacyWorker;
          assertions = legacyWorkerAssertions;
        };

        jobs = {
          entry = catalogue.job;
          kind = kindOf;
          disabledOptions = [ "namespace" "exposure" "slot" ];
          namespaceOf = planeNamespace;
        };

        # A second slot-capable root makes the cross-root collision guard executable rather than
        # merely checking two declarations in one catalogue table.
        tools = {
          catalogue = catalogue.tools;
          selector = "tool";
          kind = kindOf;
          disabledOptions = [ "namespace" ];
          namespaceOf = planeNamespace;
        };
      };

      # A real consumer can publish reports or addressing reservations beside `nixk3s.apps`.
      # Keeping this in the executable example proves that sibling `nixk3s` definitions deep-merge
      # with the factory's core output instead of replacing it at the first attribute boundary.
      extraConfig = workloads: {
        nixk3s.consumerReport = map (x: "${x.root}.${x.name}") workloads;
      };
    })
  ];

  options.nixk3s.consumerReport = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = "Enabled consumer contexts, as a fixture for extraConfig's deep module merge.";
  };
}
