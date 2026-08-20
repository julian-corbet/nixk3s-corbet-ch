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
      # ONLY THE SYSTEM THESE CHECKS CAN GENUINELY BE EVALUATED ON, which is the narrower claim and
      # the honest one. Every check here builds a real nixidy environment, and nixidy's own
      # `fromYAML` is IMPORT-FROM-DERIVATION: reading a manifest back BUILDS a derivation during
      # evaluation. An aarch64-linux derivation cannot be built by an x86_64 runner, so declaring
      # aarch64 bought no coverage and made `nix flake check --all-systems` fail outright with
      # "a 'aarch64-linux' ... is required to build ... but I am a 'x86_64-linux'".
      #
      # Keeping aarch64 and dropping `--all-systems` is the worse trade and the one this family
      # refuses: a bare `nix flake check` omits the systems it cannot evaluate and still exits 0, so
      # CI reports green having tested half of what the flake claims. Narrow the claim, keep the
      # check strict.
      #
      # Nothing else narrows: the modules are nixidy/NixOS modules and plain data, available to a
      # consumer on any system. Only `checks` and `formatter` were ever system-scoped here.
      systems = [ "x86_64-linux" ];
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
      #
      # THE ONE CATALOGUE, and it is not an exception to that: `cockpit` holds
      # the platform's OWN faces — the GitOps controller, the console, the
      # portal — which are not apps anybody has. Delete every app on the cluster
      # and that catalogue is unchanged and still has a job; a catalogue of
      # "apps you run" is empty there. It ships as its own module for exactly
      # that reason and is not part of the default.
      nixosModules = {
        k3s-host = ./modules/k3s-host;
        # Only module in this class - trivially the default.
        default = self.nixosModules.k3s-host;
      };
      nixidyModules = {
        apps = ./modules/apps;
        tenancy = ./modules/tenancy;
        addressing = ./modules/addressing;
        # The platform's own faces — the one catalogue of particular software
        # this repository keeps, and the reason it does not contradict the
        # charter above: a cockpit surface is not an app you HAVE, it is what
        # you open to see whether the thing running your apps is working.
        # It imports the grammar; the grammar cannot see it.
        cockpit = ./modules/cockpit;
        # THE GRAMMAR AND ITS INTERLOCKS, and deliberately NOT the cockpit. The
        # three below are independent — each works alone — but importing them
        # together is what makes the interlocks checkable (a destination missing
        # from a project, a slot outside its repository's band), so the default
        # carries all three. The cockpit stays out because importing "everything"
        # must not hand a consumer an opinion about which dashboards exist:
        # taking a catalogue is its own deliberate line.
        default = { imports = [ ./modules/apps ./modules/tenancy ./modules/addressing ]; };
      };

      lib = { };

      # Two checks, because this repository has two kinds of module and neither
      # was evaluated by anything before now.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # 1. The nixidy modules, rendered to real manifests. The private
          # overlay is part of the render on purpose: the app grammar's answer
          # to "my app needs a fleet fact you refuse to express" is that a
          # private module defines it on the rendered object, and a claim like
          # that is worth nothing unchecked.
          #
          # It names the GRAMMAR's modules rather than everything this flake
          # exports, and that is load-bearing rather than tidy: the cockpit is a
          # module of this class too, and it must not be in this render. "A
          # consumer can take the grammar without the cockpit" is a claim, and
          # this is the env that keeps it true — it would stop evaluating the
          # day the grammar started needing a catalogue.
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = [
              self.nixidyModules.default
              ./examples/all/values.nix
              ./examples/all/private-overlay.nix
            ];
          };

          # The cockpit, rendered against the band model — and NOT against the
          # grammar, which it imports itself. That is the other direction of the
          # same claim: composing this module alone is enough, because a
          # translator carries the vocabulary it translates into.
          cockpitEnv = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = [
              self.nixidyModules.cockpit
              self.nixidyModules.addressing
              ./examples/cockpit/values.nix
            ];
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

          # 3. The app grammar, asserted against the manifests it actually
          # PRODUCED — not merely evaluated. A grammar that type-checks and
          # renders a Deployment whose selector misses its own pods is worth
          # nothing, and only a parser looking at the output can tell.
          apps-render = import ./checks/apps-render.nix {
            inherit pkgs lib env;
          };

          # 4. The same grammar in the failing direction: every guard it makes
          # (the tenancy destinations interlock, the address-literal boundary,
          # claims-are-not-paths, the GPU wake front) gets a declaration that
          # violates it and must be refused.
          apps-fail-closed = import ./checks/apps-fail-closed.nix {
            inherit pkgs lib nixidy;
            appsModule = self.nixidyModules.apps;
            tenancyModule = self.nixidyModules.tenancy;
          };

          # 5. The band model, both directions at once, because a guard is only
          # worth what its failing direction proves: an in-band slot renders and
          # the report counts it, while an out-of-band slot, an unbound origin,
          # a full band and a doubly-claimed slot each fail eval.
          addressing = import ./checks/addressing.nix {
            inherit pkgs lib nixidy;
            appsModule = self.nixidyModules.apps;
            addressingModule = self.nixidyModules.addressing;
          };

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
          # 6. The cockpit, in both directions like the grammar it translates
          # into: an example surface that must render, and a declaration
          # violating each of its guards that must be refused — the catalogue's
          # own variables overridden, a directory that must already exist backed
          # by one that gets created, an at-rest key written as a value, an
          # identity guessed or stated where nothing reads it.
          cockpit-eval = import ./checks/cockpit-eval.nix {
            inherit pkgs lib nixidy;
            cockpitModule = self.nixidyModules.cockpit;
            addressingModule = self.nixidyModules.addressing;
            values = ./examples/cockpit/values.nix;
          };

          # 7. And the manifests it actually PRODUCED, parsed and asserted field
          # by field. A translator can resolve every option correctly and still
          # render a pod that mounts the wrong path, writes its database onto its
          # own filesystem, or carries a uid nothing reads.
          cockpit-render = import ./checks/cockpit-render.nix {
            inherit pkgs lib;
            env = cockpitEnv;
          };

          host-module-evaluates =
            pkgs.writeText "nixk3s-host-drvpath"
              (builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath);
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
