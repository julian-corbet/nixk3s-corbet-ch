# The consumer factory's second shape: several user-facing roots over several catalogues, with the
# rendering kind read from each selected entry. This is the shape needed by database and CI
# catalogues, where one root may contain both typed workloads and opaque/custom resources.
#
# Like consumer-eval, every refusal is checked by message. A type error can prove an option is
# structurally absent; it cannot prove a semantic guard said the right thing.
{ pkgs, lib, nixidy, appsModule, addressingModule, consumerModule, mkConsumerModule, values }:

let
  base = import values { };

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule addressingModule consumerModule v ];
  };

  mkEnvWithoutAddressing = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule consumerModule v ];
  };

  renders = v: (builtins.tryEval (builtins.seq (mkEnv v).environmentPackage.drvPath true)).success;

  failsWithUsing = mk: infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (mk v).config.nixidy.assertions);
    in
    r.success && r.value;

  failsWith = failsWithUsing mkEnv;
  failsWithoutAddressingWith = failsWithUsing mkEnvWithoutAddressing;

  warnsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (w: w.when && lib.hasInfix infix w.message)
        (mkEnv v).config.nixidy.warnings);
    in
    r.success && r.value;

  selectorCatalogue.only = {
    image = "registry.example.com/example-org/selector-fixture";
    ports = { };
    primaryPort = null;
    state = { };
  };

  mkSelectorConsumer = namespace: selector: extra:
    mkConsumerModule ({
      inherit namespace selector;
      catalogue = selectorCatalogue;
    } // extra);

  selectorValues = namespace: selector: {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    ${namespace} = {
      clusterPlatform = {
        namespace = "example-selector";
        project = "example";
      };
      applications.one = {
        ${selector} = "only";
      } // lib.optionalAttrs (selector != "version") {
        version = "1.0.0";
      };
    };
  };

  selectorFactoryEvaluates = module: values':
    (builtins.tryEval (builtins.seq
      (nixidy.lib.mkEnv {
        inherit pkgs;
        modules = [ appsModule module values' ];
      }).config.nixk3s.apps.one.image
      true)).success;

  rejectsOptionPath = optionPath:
    let
      module = mkConsumerModule {
        namespace = "nixinvalidpath";
        inherit optionPath;
        catalogue = selectorCatalogue;
        selector = "service";
      };
      result = builtins.tryEval (builtins.deepSeq
        (module { config = { }; inherit lib; options = { }; }).options
        true);
    in
    !result.success;

  nestedConsumerModule = mkConsumerModule {
    namespace = "nixnested";
    optionPath = [ "nixnested" "cluster" ];
    catalogue = selectorCatalogue;
    selector = "service";
  };

  nestedCfg = (nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [
      appsModule
      nestedConsumerModule
      {
        options.nixnested.hostSurface = lib.mkOption { type = lib.types.str; };
        config.nixnested.hostSurface = "preserved sibling";
      }
      {
        nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
        nixidy.target.branch = "main";
        nixnested.cluster = {
          clusterPlatform = {
            namespace = "example-nested";
            project = "example";
          };
          applications.one = {
            service = "only";
            version = "1.0.0";
          };
        };
      }
    ];
  }).config;

  flatPlatformConsumer = mkConsumerModule {
    namespace = "nixflatplatform";
    publishPlatformOptions = false;
    platformOf = { consumer, ... }: {
      inherit (consumer) namespace project origin;
    };
    originOptionPath = [ "nixflatplatform" "origin" ];
    catalogue = selectorCatalogue;
    selector = "service";
    extraNamespaceOptions = {
      namespace = lib.mkOption { type = lib.types.str; };
      project = lib.mkOption { type = lib.types.str; };
      origin = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };

  flatPlatformEnv = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [
      appsModule
      flatPlatformConsumer
      ({ options, ... }: {
        nixidy.assertions = [{
          assertion = !(options.nixflatplatform ? clusterPlatform);
          message = "fixture: a flat domain platform must not publish nested platform options";
        }];
      })
      {
        nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
        nixidy.target.branch = "main";
        nixflatplatform = {
          namespace = "example-flat-platform";
          project = "example-flat-project";
          applications.one = {
            service = "only";
            version = "1.0.0";
          };
        };
      }
    ];
  };

  flatPlatformCfg = flatPlatformEnv.config;

  # A consumer may force the generated app while collecting a wholly separate assertion. Missing
  # image inputs must still be reported by the factory's own guard rather than throwing while the
  # app is constructed and hiding both diagnostics behind a null interpolation.
  missingVersionConsumer = mkConsumerModule {
    namespace = "nixmissingversion";
    catalogue = selectorCatalogue;
    selector = "service";
  };

  missingVersionEnv = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [
      appsModule
      missingVersionConsumer
      ({ config, ... }: {
        nixidy.assertions = [{
          assertion = builtins.deepSeq config.nixk3s.apps.one false;
          message = "fixture: the generated app was forced by an unrelated assertion";
        }];
      })
      {
        nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
        nixidy.target.branch = "main";
        nixmissingversion = {
          clusterPlatform = {
            namespace = "example-missing-version";
            project = "example";
          };
          applications.one.service = "only";
        };
      }
    ];
  };

  missingVersionIsTotal =
    let
      result = builtins.tryEval (
        let
          assertions = missingVersionEnv.config.nixidy.assertions;
          expected = lib.any
            (a: !a.assertion && lib.hasInfix "says neither which version" a.message)
            assertions;
          unrelated = lib.any
            (a: !a.assertion && lib.hasInfix "forced by an unrelated assertion" a.message)
            assertions;
        in
        builtins.deepSeq [ expected unrelated ] (expected && unrelated));
    in
    result.success && result.value;

  # Some established consumers use semantic camelCase state keys in their public declaration
  # contract even though a Kubernetes volume name must be a DNS label. The root resolver keeps
  # those two identities separate: declarations stay source-compatible while every rendered use
  # of the volume takes the catalogue's explicit Kubernetes name.
  volumeCatalogue.legacy = {
    image = "registry.example.com/example-org/legacy";
    ports = { };
    primaryPort = null;
    state = {
      legacyData = "/srv/legacy/data";
      cacheData = "/srv/legacy/cache";
    };
    volumeNames = {
      legacyData = "legacy-data";
      cacheData = "cache-data";
    };
    companions.reader = {
      image = null;
      ports = { };
      primaryPort = null;
      mounts.cacheData = [{ mountPath = "/srv/reader/cache"; }];
    };
    init = [{
      name = "seed";
      image = null;
      command = [ "sh" "-c" ];
      args = [ "test -d /srv/seed/data" ];
      mounts.legacyData = [{ mountPath = "/srv/seed/data"; }];
    }];
  };

  volumeCatalogue.shared = {
    image = "registry.example.com/example-org/shared-state";
    ports = { };
    primaryPort = null;
    state = {
      userfiles = "/srv/app/userfiles";
      plugins = "/srv/app/plugins";
      logs = "/srv/app/logs";
    };
    volumeNames.userfiles = "data";
    companions.reader = {
      image = null;
      ports = { };
      primaryPort = null;
      mounts.plugins = [{ mountPath = "/srv/reader/plugins"; }];
    };
  };

  catalogueVolumeNameOf = { entry, ... }: key: entry.volumeNames.${key} or key;

  mkVolumeConsumer = resolver: mkConsumerModule {
    namespace = "nixvolume";
    roots.workloads = {
      catalogue = volumeCatalogue;
      selector = "service";
      volumeNameOf = resolver;
    };
  };

  volumeValues = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixvolume = {
      clusterPlatform = {
        namespace = "example-volume";
        project = "example";
      };
      workloads.one = {
        service = "legacy";
        version = "1.0.0";
        state = {
          legacyData.hostPath = "/example/legacy/data";
          cacheData.hostPath = "/example/legacy/cache";
        };
      };
      workloads.two = {
        service = "shared";
        version = "1.0.0";
        state = {
          userfiles = {
            hostPath = "/example/shared";
            subPath = "userfiles";
            mountOrder = 0;
          };
          plugins = {
            sharedWith = "userfiles";
            subPath = "plugins";
            mountOrder = 1;
          };
          logs = {
            sharedWith = "userfiles";
            subPath = "logs";
            mountOrder = 2;
          };
        };
      };
    };
  };

  mkVolumeEnv = resolver: v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule (mkVolumeConsumer resolver) v ];
  };

  volumeRenders = resolver:
    (builtins.tryEval (builtins.seq (mkVolumeEnv resolver volumeValues).environmentPackage.drvPath true)).success;

  volumeCfg = (mkVolumeEnv catalogueVolumeNameOf volumeValues).config;

  volumeWith = state: lib.recursiveUpdate volumeValues {
    nixvolume.workloads.two.state = state;
  };
  sharedState = volumeValues.nixvolume.workloads.two.state;

  with' = f: lib.recursiveUpdate base f;
  configOf = v: (mkEnv v).config;
  cfg = configOf base;
  names = xs: lib.sort (a: b: a < b) xs;
  vendorManifests = base.nixmulti.services.vendor.generatedManifests;

  addressed = with' {
    nixmulti.clusterPlatform.origin = "nixmulti";
    nixmulti.services.vendor.slot = 71;
    nixmulti.services.external.slot = 72;
    nixk3s.addressing = {
      enable = true;
      bands.consumer = {
        base = 64;
        description = "consumer factory fixture";
      };
      bindings.nixmulti = "consumer";
      fallbackBand = "consumer";
    };
  };
  addressedCfg = configOf addressed;

  missingAddressing = with' {
    # Leave only a direct holder. Grammar apps would themselves require the addressing module as
    # soon as origin is set, obscuring the reservation-specific factory assertion under test.
    nixmulti.services.web.enable = false;
    nixmulti.workers.agent.enable = false;
    nixmulti.clusterPlatform.origin = "nixmulti";
    nixmulti.services.vendor.slot = 71;
  };

  withoutWorkerVersion = base // {
    nixmulti = base.nixmulti // {
      workers = base.nixmulti.workers // {
        agent = builtins.removeAttrs base.nixmulti.workers.agent [ "version" ];
      };
    };
  };

  oneManifest = ''
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: deliberate-failure
  '';

  results = {
    "the mixed, multi-root surface renders" = renders base;

    "selector names are disjoint from common and extra option paths" =
      selectorFactoryEvaluates
        (mkSelectorConsumer "nixselectorcontrol" "service" { })
        (selectorValues "nixselectorcontrol" "service")
      && !selectorFactoryEvaluates
        (mkSelectorConsumer "nixselectorcommon" "version" { })
        (selectorValues "nixselectorcommon" "version")
      && !selectorFactoryEvaluates
        (mkSelectorConsumer "nixselectorextra" "service" {
          extraOptions.service = lib.mkOption { type = lib.types.str; };
        })
        (selectorValues "nixselectorextra" "service");

    "optionPath preserves an existing nested public option tree without an adapter" =
      nestedCfg.nixnested.cluster.applications.one.service == "only"
      && !(nestedCfg.nixnested ? applications)
      && nestedCfg.nixnested.hostSurface == "preserved sibling"
      && nestedCfg.nixk3s.apps.one.image
        == "registry.example.com/example-org/selector-fixture:1.0.0";

    "optionPath rejects shapes that cannot name a module option tree" =
      rejectsOptionPath "nixinvalidpath"
      && rejectsOptionPath [ ]
      && rejectsOptionPath [ "nixinvalidpath" "" ]
      && rejectsOptionPath [ "nixinvalidpath" 1 ];

    "a typed domain platform can leave no nested platform option subtree" =
      !(flatPlatformCfg.nixflatplatform ? clusterPlatform)
      && lib.any
        (a: a.assertion
          && a.message == "fixture: a flat domain platform must not publish nested platform options")
        flatPlatformCfg.nixidy.assertions
      && flatPlatformCfg.nixk3s.apps.one.namespace == "example-flat-platform"
      && flatPlatformCfg.nixk3s.apps.one.project == "example-flat-project";

    "suppressing platform publication requires a resolver" =
      !selectorFactoryEvaluates
        (mkSelectorConsumer "nixinvalidplatformresolver" "service" {
          publishPlatformOptions = false;
        })
        (selectorValues "nixinvalidplatformresolver" "service");

    "ordinary extra platform options still cannot replace built-in names" =
      !selectorFactoryEvaluates
        (mkSelectorConsumer "nixinvalidplatformcollision" "service" {
          extraPlatformOptions.project = lib.mkOption { type = lib.types.str; };
        })
        (selectorValues "nixinvalidplatformcollision" "service");

    "missing image inputs remain total when another assertion forces the generated app" =
      missingVersionIsTotal;

    "a root resolves legacy camelCase state keys to explicit Kubernetes volume names everywhere" =
      volumeRenders catalogueVolumeNameOf
      && volumeCfg.nixvolume.workloads.one.state ? legacyData
      && volumeCfg.nixvolume.workloads.one.state ? cacheData
      && !(volumeCfg.nixk3s.apps.one.state ? legacyData)
      && !(volumeCfg.nixk3s.apps.one.state ? cacheData)
      && volumeCfg.nixk3s.apps.one.state."legacy-data".hostPath == "/example/legacy/data"
      && volumeCfg.nixk3s.apps.one.state."cache-data".hostPath == "/example/legacy/cache"
      && builtins.hasAttr "cache-data" volumeCfg.nixk3s.apps.one.companions.reader.mounts
      && builtins.hasAttr "legacy-data" (lib.head volumeCfg.nixk3s.apps.one.init).mounts;

    "an invalid root-resolved volume name is still refused by the shared DNS guard" =
      failsWithUsing (mkVolumeEnv (_context: _key: "Not_A_Label")) "will not accept as a name" volumeValues;

    "two root-resolved state keys colliding on one volume name are refused centrally" =
      failsWithUsing (mkVolumeEnv (_context: _key: "same")) "onto one volume name" volumeValues;

    "semantic state directories can share one physical backing in declared mount order" =
      volumeCfg.nixk3s.apps.two.state ? data
      && lib.attrNames volumeCfg.nixk3s.apps.two.state == [ "data" ]
      && volumeCfg.nixk3s.apps.two.state.data.hostPath == "/example/shared"
      && map (m: m.mountPath) volumeCfg.nixk3s.apps.two.state.data.mounts == [
        "/srv/app/userfiles"
        "/srv/app/plugins"
        "/srv/app/logs"
      ]
      && map (m: m.subPath) volumeCfg.nixk3s.apps.two.state.data.mounts == [
        "userfiles"
        "plugins"
        "logs"
      ]
      && volumeCfg.nixk3s.apps.two.companions.reader.mounts.data == [{
        mountPath = "/srv/reader/plugins";
        subPath = "plugins";
        readOnly = false;
      }];

    "shared state refuses an unknown or chained owner" =
      failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "unknown, self-referential, or itself-shared"
        (volumeWith (sharedState // { plugins.sharedWith = "missing"; }))
      && failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "unknown, self-referential, or itself-shared"
        (volumeWith (sharedState // { logs.sharedWith = "plugins"; }));

    "shared state refuses a second physical backing" =
      failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "both a `sharedWith` target and physical"
        (volumeWith (sharedState // { plugins.hostPath = "/example/duplicate"; }));

    "shared state refuses implicit roots and nondeterministic mount order" =
      failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "every member both `subPath` and `mountOrder`"
        (volumeWith (sharedState // { plugins.subPath = null; }))
      && failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "same `mountOrder`"
        (volumeWith (sharedState // { plugins.mountOrder = 0; }));

    "shared state refuses duplicate and escaping subpaths" =
      failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "same subPath"
        (volumeWith (sharedState // { plugins.subPath = "userfiles"; }))
      && failsWithUsing (mkVolumeEnv catalogueVolumeNameOf) "unsafe `subPath`"
        (volumeWith (sharedState // { plugins.subPath = "../plugins"; }));

    "entries from two roots reach the app grammar" =
      cfg.nixmulti.renderedByGrammar == [ "agent" "web" ]
      && names (lib.attrNames cfg.nixk3s.apps) == [ "agent" "web" ];

    "extraConfig can publish a sibling nixk3s subtree without replacing grammar apps" =
      names (lib.attrNames cfg.nixk3s.apps) == [ "agent" "web" ]
      && names cfg.nixk3s.consumerReport == [
        "jobs.zz-nightly"
        "services.external"
        "services.vendor"
        "services.web"
        "tools.aardvark"
        "workers.agent"
      ];

    "a chart and a fixed synthetic job take the one manifest route" =
      cfg.nixmulti.renderedDirectly == [ "vendor" "zz-nightly" ]
      && cfg.applications.vendor.syncPolicy.syncOptions.serverSideApply == "ServerSideApply=true"
      && cfg.applications.vendor.compareOptions.serverSideDiff == "ServerSideDiff=true"
      && cfg.applications.vendor.yamls == vendorManifests
      && cfg.applications.zz-nightly.syncPolicy.syncOptions.serverSideApply == "ServerSideApply=true";

    "reserved rendering reports sort globally rather than by root traversal" =
      cfg.nixmulti.renderedByGrammar == [ "agent" "web" ]
      && cfg.nixmulti.renderedDirectly == [ "vendor" "zz-nightly" ]
      && cfg.nixmulti.notRendered == [ "aardvark" "external" ];

    "manifestsOf, not a hard-coded declaration field, supplies exact direct YAML" =
      cfg.nixmulti.services.vendor.manifests == [ ]
      && cfg.nixmulti.services.vendor.generatedManifests == vendorManifests
      && cfg.applications.vendor.yamls == vendorManifests;

    "extensions cannot override resolver identity, tenancy, or direct-delivery safety" =
      cfg.nixk3s.apps.web.name == "frontend"
      && cfg.nixk3s.apps.web.namespace == "example-control"
      && cfg.nixk3s.apps.web.project == "example"
      && cfg.nixk3s.apps.web.createNamespace
      && cfg.applications.vendor.namespace == "example-control"
      && cfg.applications.vendor.project == "example"
      && !cfg.applications.vendor.createNamespace
      && cfg.applications.vendor.yamls == vendorManifests
      && cfg.applications.vendor.syncPolicy.syncOptions.serverSideApply == "ServerSideApply=true"
      && cfg.applications.vendor.compareOptions.serverSideDiff == "ServerSideDiff=true";

    "a mixed root can replace common credentials with roles and render them through extend" =
      cfg.nixk3s.apps.web.secrets.admin.secret == "example-web-credentials"
      && cfg.nixk3s.apps.web.secrets.admin.env.WEB_TOKEN == "token"
      && cfg.nixmulti.services.vendor.credentials.chartToken.key == "chart-token"
      && cfg.applications.vendor.yamls == vendorManifests;

    "a root can replace state and sizing without the common renderer inspecting their shape" =
      builtins.hasAttr "agent-config" cfg.nixk3s.apps.agent.state
      && !(builtins.hasAttr "config" cfg.nixk3s.apps.agent.state)
      && cfg.nixk3s.apps.agent.state."agent-config".secret == "example-agent-config"
      && cfg.nixk3s.apps.agent.state."agent-config".ownership == "site-curated"
      && cfg.nixk3s.apps.agent.resources.requests == { cpu = "25m"; memory = "32Mi"; }
      && cfg.nixk3s.apps.agent.resources.limits == { memory = "128Mi"; }
      && builtins.hasAttr "agent-config" cfg.nixk3s.apps.agent.companions.telemetry.mounts
      && cfg.nixk3s.apps.agent.companions.telemetry.resources.requests
        == { cpu = "5m"; memory = "8Mi"; }
      && builtins.hasAttr "agent-config" (lib.head cfg.nixk3s.apps.agent.init).mounts;

    "a state replacement carries its own domain safety assertion" =
      failsWith "legacy state paths must be absolute: `config`"
        (with' { nixmulti.workers.agent.state.config.path = "relative/agent.conf"; });

    "extraOptions can refine an enabled common option while retaining shared rendering" =
      cfg.nixmulti.workers.agent.version == "2.0.0"
      && cfg.nixk3s.apps.agent.image == "registry.example.com/example-org/agent:2.0.0"
      && !renders withoutWorkerVersion;

    "the replacement credential shape carries its own required-role guard" =
      failsWith "missing required credential roles: admin"
        (with' { nixmulti.services.web.credentials = lib.mkForce { }; });

    "required state remains required when other catalogue state is optional" =
      failsWith "marks required, and is missing `data`"
        (with' { nixmulti.services.web.state = lib.mkForce { }; });

    "an enabled common state term may narrow its public backing schema" =
      cfg.nixk3s.apps.web.state.data.hostPath == "/example/state/web"
      && cfg.nixk3s.apps.web.state.data.ownership == "site-curated"
      && !renders (with' { nixmulti.services.web.state.cache.emptyDir = true; });

    "ordinary optional state may be absent or deliberately backed" =
      !(cfg.nixmulti.services.web.state ? cache)
      && renders (with' {
        nixmulti.services.web.state.cache.hostPath = "/example/cache/web";
      });

    "conditional state is refused while forbidden and accepted when its mode enables it" =
      failsWith "catalogued state for `web` but forbidden"
        (with' {
          nixmulti.services.web.state.archive.hostPath = "/example/archive/web";
        })
      && renders (with' {
        nixmulti.services.web.storageMode = "archive";
        nixmulti.services.web.state.archive.hostPath = "/example/archive/web";
      });

    "a reference is reported and renders no Application" =
      cfg.nixmulti.notRendered == [ "aardvark" "external" ]
      && !(cfg.applications ? external)
      && !(cfg.applications ? aardvark)
      && !(cfg.nixk3s.apps ? external)
      && !(cfg.nixk3s.apps ? aardvark);

    "an entry supplies a deployment default without putting the value in the catalogue renderer" =
      cfg.nixk3s.apps.web.exposure == "nb"
      && (configOf (with' { nixmulti.services.web.exposure = "public"; })).nixk3s.apps.web.exposure
        == "public";

    "nameOf is the one resolved identity for grammar apps as well as direct manifests" =
      cfg.nixk3s.apps.web.name == "frontend";

    "namespaces are derived from catalogue planes, with no per-workload namespace option" =
      cfg.nixk3s.apps.web.namespace == "example-control"
      && cfg.nixk3s.apps.agent.namespace == "example-execution"
      && cfg.applications.zz-nightly.namespace == "example-control";

    "all-derived roots need no meaningless singular platform namespace" =
      !(cfg.nixmulti.clusterPlatform ? namespace);

    "an entry disabled by default is absent until the declaration explicitly enables it" =
      !(cfg.nixk3s.apps ? parked)
      && (configOf (with' {
          nixmulti.services.parked = {
            enable = true;
            version = "1.0.0";
          };
        })).nixk3s.apps ? parked;

    "whole manifests beside an app are refused as a second renderer" =
      failsWith "two authorities"
        (with' { nixmulti.services.web.manifests = [ oneManifest ]; });

    "a reference carrying manifests is refused" =
      failsWith "is a reference and carries manifests"
        (with' { nixmulti.services.external.manifests = [ oneManifest ]; });

    "a direct manifest cannot anchor a namespace without prune protection" =
      failsWith "cannot stamp the grammar's prune protection"
        (with' { nixmulti.services.vendor.createNamespace = true; });

    "a reference cannot claim to anchor a namespace while rendering nothing" =
      failsWith "a reference renders no object at all"
        (with' { nixmulti.services.external.createNamespace = true; });

    "a misspelt entry kind is refused instead of disappearing from every partition" =
      failsWith "unknown rendering kind `misspelt`"
        (with' { nixmulti.services.broken.service = "invalid"; });

    "a non-string entry kind reaches the same fail-closed assertion" =
      failsWith "unknown rendering kind `<lambda>`"
        (with' { nixmulti.services.broken-type.service = "invalid-type"; });

    "one workload name in two roots is refused before one Application overwrites the other" =
      failsWith "appears in more than one root"
        (with' {
          nixmulti.workers.web = {
            worker = "agent";
            version = "2.0.0";
          };
        });

    "a direct Application cannot merge into a grammar Application's declaration key" =
      failsWith "Application option key `web`"
        (with' {
          nixmulti.services.shadow = {
            service = "vendor";
            objectName = "web";
            generatedManifests = [ oneManifest ];
          };
        });

    "two declarations resolving through nameOf to one identity are refused centrally" =
      failsWith "rendered name `frontend` is produced by more than one declaration"
        (with' {
          nixmulti.services.alias = {
            service = "web";
            version = "1.0.0";
            credentials.admin = {
              secret = "example-alias-credentials";
              key = "token";
            };
            state.data.hostPath = "/example/state/alias";
          };
        });

    "one slot claimed from two different roots is refused centrally" =
      failsWith "slot 70 is claimed by 2 workloads"
        (with' {
          nixmulti.tools.inspector = {
            tool = "inspector";
            slot = 70;
          };
        });

    "execution roots structurally have no exposure option" =
      !renders (with' { nixmulti.workers.agent.exposure = "internal"; });

    "built-in warnings ignore common terms a root structurally omits" =
      !warnsWith "workload `agent` asks for no CPU or memory" base
      && !warnsWith "workload `agent` is declared scale-to-zero with no wake front"
        (with' { nixmulti.workers.agent.scaling = "scale-to-zero"; });

    "built-in warnings remain active where the root exposes those terms" =
      warnsWith "workload `web` asks for no CPU or memory" base
      && warnsWith "workload `web` is declared scale-to-zero with no wake front"
        (with' { nixmulti.services.web.scaling = "scale-to-zero"; });

    "fixed-entry roots structurally have no invented selector" =
      !renders (with' { nixmulti.jobs.zz-nightly.app = "job"; });

    "an empty manifest delivery warns and renders no direct Application" =
      warnsWith "manifest delivery with no manifests"
        (with' { nixmulti.services.elsewhere.service = "vendor"; });

    "slots are collected across every root that actually exposes the term" =
      cfg.nixmulti.clusterSlots == { web = 70; };

    "manifest and reference slots become addressing reservations when an origin is active" =
      renders addressed
      && names (lib.attrNames addressedCfg.nixk3s.addressing.reservations) == [ "external" "vendor" ]
      && addressedCfg.nixk3s.addressing.reservations.vendor == {
        slot = 71;
        origin = "nixmulti";
        note = "services.vendor, delivered as manifest by nixmulti";
      }
      && addressedCfg.nixk3s.addressing.reservations.external == {
        slot = 72;
        origin = "nixmulti";
        note = "services.external, delivered as reference by nixmulti";
      };

    "below-grammar slots fail closed when origin is set without the addressing module" =
      failsWithoutAddressingWith "addressing module is not composed" missingAddressing;
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in

pkgs.runCommand "nixk3s-consumer-multi-root" { } ''
  ${lib.optionalString (failed != [ ]) ''
    echo "nixk3s consumer-multi-root FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):"
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}"'') failed}
    exit 1
  ''}
  echo "nixk3s: all ${toString (lib.length (lib.attrNames results))} multi-root properties hold"
  touch $out
''
