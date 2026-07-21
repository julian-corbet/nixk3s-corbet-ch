{
  description = "nixk3s - bare-metal k3s on NixOS with a declarative nixidy + Argo CD GitOps spine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      # Extraction in progress: this repo is being pulled out of a private
      # production configuration. Planned module attrset, in extraction order:
      #
      #   nixosModules.k3s-host        - k3s server, node labels, airgap images, storage conventions
      #   kubernetesModules.gitops-spine - nixidy env pattern + Argo CD bootstrap (render -> sync)
      #   kubernetesModules.tenancy    - the AppProject tenancy model
      nixosModules = { };
      kubernetesModules = { };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
