{ }:
{
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixmulti.clusterPlatform = {
    # The base platform namespace is deliberately not set. These roots derive it from the
    # catalogue entry's plane, and `namespace` is not an option on any declaration below.
    project = "example";
    controlNamespace = "example-control";
    executionNamespace = "example-execution";
  };

  nixmulti.services = {
    web = {
      service = "web";
      version = "1.0.0";
      createNamespace = true;
      slot = 70;
      credentials.admin = {
        secret = "example-web-credentials";
        key = "token";
      };
      state.data.hostPath = "/example/state/web";
      # `exposure` is omitted: the catalogue-backed per-entry default supplies `nb`.
    };

    vendor = {
      service = "vendor";
      generatedManifests = [ ''
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: example-vendor
          namespace: example-control
        data:
          source: vendor
      '' ];
      credentials.chartToken = {
        secret = "example-vendor-credentials";
        key = "chart-token";
      };
    };

    # Declared so other roots can name it; rendered nowhere because the catalogue says reference.
    external.service = "external";

    # No explicit `enable = false`: the catalogue entry supplies that default. This declaration
    # must remain absent from every rendered/reporting set until a consumer deliberately enables it.
    parked.service = "parked";
  };

  nixmulti.workers.agent = {
    worker = "agent";
    version = "2.0.0";
    # `namespace`, `exposure`, `slot`, and `wake` are structurally absent on this root. State and
    # sizing use deliberately incompatible legacy records, translated by the root's `extend`.
    state.config = {
      secret = "example-agent-config";
      key = "agent.conf";
      path = "/etc/agent/agent.conf";
      owner = "site-curated";
      volumeName = "agent-config";
    };
    resources = {
      requests = { cpu = "25m"; memory = "32Mi"; };
      limits.memory = "128Mi";
    };
    companionResources.telemetry = {
      requests = { cpu = "5m"; memory = "8Mi"; };
      limits.memory = "32Mi";
    };
  };

  # This root follows `services` in root order but its declaration name sorts before `external`.
  # The report check therefore proves sorting is global rather than merely stable within a root.
  nixmulti.tools.aardvark.tool = "inspector";

  # Conversely, this fixed root precedes `services` but its name sorts after `vendor`.
  nixmulti.jobs.zz-nightly.manifests = [ ''
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: example-nightly
      namespace: example-control
    spec:
      schedule: "0 4 * * *"
      jobTemplate:
        spec:
          template:
            spec:
              restartPolicy: Never
              containers:
                - name: sweep
                  image: registry.example.com/example-org/sweep:1
  '' ];
}
