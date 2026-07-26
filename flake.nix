{
  description = "nixk3s - bare-metal k3s on NixOS with a declarative nixidy + Argo CD GitOps spine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixidy renders the tenancy module to Argo CD manifests. A real input, not
    # just a name in the description: without it there is no module system to
    # evaluate tenancy against, and `nix flake check` passes by checking nothing.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixidy }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # Extracted from a production single-node cluster; generalized forms not
      # yet re-verified live. The GitOps spine itself (render -> commit -> sync)
      # is documented in docs/SPINE.md.
      #
      # This repository holds the MECHANISM: the host, the spine, and tenancy
      # governance. It deliberately knows nothing about what kind of apps you
      # run — no taxonomy of application categories exists here, because that
      # belongs to whatever ships the apps.
      nixosModules = {
        k3s-host = ./modules/k3s-host;
      };
      nixidyModules = {
        tenancy = ./modules/tenancy;
      };

      lib = { };

      # Two checks, because this repository has two kinds of module and neither
      # was evaluated by anything before now.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # 1. The nixidy module, rendered to real manifests.
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = lib.attrValues self.nixidyModules
              ++ [ ./examples/all/values.nix ];
          };

          # 2. The NixOS module, composed into a real system. Only the stubs a
          # bootable config demands are supplied — this is about whether the
          # module composes, not about producing a machine anyone would run.
          host = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.k3s-host
              ./examples/host/configuration.nix
            ];
          };
        in
        {
          tenancy-renders = env.environmentPackage;

          # Forcing the derivation PATH evaluates the whole NixOS configuration —
          # every option, assertion and type check the module participates in —
          # without building a system closure. An eval error fails the check; a
          # kernel does not get downloaded.
          #
          # The string context MUST be discarded. A store path inside a string is
          # tracked by Nix as a build dependency, so writing the .drvPath with its
          # context intact makes this check *build* the entire NixOS system rather
          # than merely evaluate it — turning a few seconds into many minutes and
          # a multi-gigabyte download. Dropping the context keeps the evaluation
          # (which is the thing being checked) and discards the closure (which is
          # not).
          host-module-evaluates =
            pkgs.writeText "nixk3s-host-drvpath"
              (builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath);
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
