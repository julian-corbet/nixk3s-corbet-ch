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
      # Extracted from a production single-node cluster; generalized forms not
      # yet re-verified live. The GitOps spine itself (render -> commit -> sync)
      # is documented in docs/SPINE.md.
      nixosModules = {
        k3s-host = ./modules/k3s-host;
      };
      nixidyModules = {
        tenancy = ./modules/tenancy;
      };

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
