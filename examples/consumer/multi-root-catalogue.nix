{ }:
{
  services = {
    web = {
      delivery = "app";
      plane = "control";
      renderName = "frontend";
      enabledByDefault = true;
      defaultExposure = "nb";
      image = "registry.example.com/example-org/web";
      ports.http = 8080;
      primaryPort = "http";
      state = {
        data = "/var/lib/example-web";
        cache = "/var/cache/example-web";
        archive = "/srv/example-web-archive";
      };
      requiredStateKeys = [ "data" ];
      archiveStateKey = "archive";
      credentials.admin = {
        env = "WEB_TOKEN";
        required = true;
      };
    };

    parked = {
      delivery = "app";
      plane = "control";
      # A catalogue may ship an entry that is useful but normally absent. This decides only the
      # declaration's DEFAULT; a consumer can still set `enable = true` explicitly.
      enabledByDefault = false;
      image = "registry.example.com/example-org/parked";
      ports.http = 8081;
      primaryPort = "http";
      state = { };
    };

    vendor = {
      delivery = "manifest";
      plane = "control";
      credentials.chartToken = {
        # A chart consumes this through its values rather than app environment rendering.
        env = null;
        required = true;
      };
    };

    external = {
      delivery = "reference";
      plane = "control";
    };

    invalid = {
      delivery = "misspelt";
      plane = "control";
    };

    invalid-type = {
      # Deliberately not a string: callback results sit outside the module option type system and
      # must still reach the factory's useful unknown-kind assertion instead of raw equality.
      delivery = _: null;
      plane = "control";
    };
  };

  workers.agent = {
    delivery = "app";
    plane = "execution";
    image = "registry.example.com/example-org/agent";
    ports = { };
    primaryPort = null;
    state = { };
    singleWriter = true;
    companions.telemetry = {
      mounts.config = [{
        mountPath = "/etc/telemetry/agent.conf";
        subPath = "agent.conf";
        readOnly = true;
      }];
    };
    init = [{
      name = "prepare-agent";
      command = [ "sh" "-c" ];
      args = [ "test -r /etc/prepare/agent.conf" ];
      mounts.config = [{
        mountPath = "/etc/prepare/agent.conf";
        subPath = "agent.conf";
        readOnly = true;
      }];
    }];
  };

  tools.inspector = {
    delivery = "reference";
    plane = "control";
  };

  # A schedule is not software and has no catalogue key. A fixed synthetic entry lets the jobs
  # root participate in every cross-root guard without inventing a selector for it.
  job = {
    delivery = "manifest";
    plane = "control";
  };
}
