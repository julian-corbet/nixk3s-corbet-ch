{ lib, config, pkgs, ... }:

let
  cfg = config.nixk3s.host;

  nodeLabelFlags = lib.mapAttrsToList
    (name: value: "--node-label=${name}=${value}")
    cfg.nodeLabels;

  disableFlags = map (c: "--disable=${c}") cfg.disableComponents;
in
{
  options.nixk3s.host = {
    enable = lib.mkEnableOption "a declarative bare-metal k3s host";

    role = lib.mkOption {
      type = lib.types.enum [ "server" "agent" ];
      default = "server";
      description = ''
        k3s role for this node. `"server"` runs the control plane (and, on a
        single-node cluster, also schedules workloads); `"agent"` joins an
        existing control plane as a worker only.
      '';
    };

    nodeLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { "gpu" = "amd"; };
      description = ''
        Kubernetes node labels applied via `--node-label=<key>=<value>` flags.

        **Operational lesson (must read before relying on this):** k3s only
        applies `--node-label` at *first node registration*. On a node that
        is already registered in the cluster's datastore, changing this
        option and re-running `nixos-rebuild switch` updates the *declared*
        flag but does **not** change the live node object — the label silently
        stays whatever it was. If you add or rename a label here after first
        boot, you must also apply it once, live, with
        `kubectl label node <name> <key>=<value> --overwrite`. Forgetting
        this step does not error anywhere: every workload that selects on
        the label (nodeSelector/affinity) simply Pends forever with no
        obvious link back to this option.
      '';
    };

    airgapImages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        A list of container-image tarballs (e.g. the output of
        `pkgs.dockerTools.buildImage`/`streamLayeredImage`) to import into
        k3s's airgap image directory before the k3s service starts
        (`services.k3s.images`). Use this for cluster-internal images that
        have no public registry to pull from: the host builds the image into
        its own Nix closure, and k3s links it into
        `/var/lib/rancher/k3s/agent/images` so `imagePullPolicy: Never`
        deployments resolve locally. Nodes never build images themselves —
        the closure is built where it's built (e.g. CI/a build host) and
        shipped as a store path.
      '';
    };

    disableComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "traefik" "servicelb" "local-storage" ];
      description = ''
        k3s bundled components to disable via `--disable=<name>`. The default
        turns off k3s's batteries-included Traefik ingress, ServiceLB load
        balancer, and local-path storage provisioner — generic hygiene for a
        host that brings its own ingress, load-balancer, and storage
        provisioning through the GitOps spine instead of k3s's built-ins.
        Set to `[ ]` to keep everything k3s ships by default.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--kubelet-arg=max-pods=250" ];
      description = ''
        Additional raw flags appended to `services.k3s.extraFlags`, for
        anything this module doesn't model as its own option (CIDR ranges,
        TLS SANs, kubelet args, a pinned node name/IP, a snapshotter choice,
        and so on all belong here until/unless they earn a dedicated
        option).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.k3s.enable = lib.mkDefault true;
    services.k3s.role = cfg.role;

    services.k3s.extraFlags = lib.mkDefault (
      nodeLabelFlags ++ disableFlags ++ cfg.extraFlags
    );

    services.k3s.images = lib.mkIf (cfg.airgapImages != [ ]) cfg.airgapImages;
  };
}
