{
  description = "Cross-platform dev environment - scope-based package set";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      cfg = import ./config.nix;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      mkEnv = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = cfg.allowUnfree or false;
          };

          # always include base packages
          basePkgs = import ./scopes/base.nix { inherit pkgs; };

          # include init packages when no system-wide curl/jq
          initPkgs = if cfg.isInit or false
            then import ./scopes/base_init.nix { inherit pkgs; }
            else [ ];

          # include packages from enabled scopes
          scopePkgs = builtins.concatMap (scope:
            let file = ./scopes/${scope}.nix;
            in if builtins.pathExists file
              then import file { inherit pkgs; }
              else [ ]
          ) (cfg.scopes or [ ]);

          # include ad-hoc user packages from packages.nix (managed by nx CLI)
          extraNames = if builtins.pathExists ./packages.nix
            then import ./packages.nix
            else [ ];
          extraPkgs = map (name: pkgs.${name}) extraNames;

          # Packages that ship a file another package in the env also owns.
          # buildEnv aborts the whole build on a duplicate path, so the loser of
          # each known conflict is demoted with lowPrio: it still installs, minus
          # the clashing file. Applied to every source of packages (scopes and
          # ad-hoc `nx add`) so the conflict cannot come back through packages.nix.
          #   minikube - bin/kubectl is a symlink to minikube itself and collides
          #              with kubectl from the k8s_base scope. `minikube kubectl`
          #              is unaffected.
          collisionLowPrio = [ "minikube" ];
          demote = pkg:
            if builtins.elem (pkgs.lib.getName pkg) collisionLowPrio
            then pkgs.lib.lowPrio pkg
            else pkg;

        in pkgs.buildEnv {
          name = "dev-env";
          paths = map demote (basePkgs ++ initPkgs ++ scopePkgs ++ extraPkgs);
        };
    in
    {
      packages = nixpkgs.lib.genAttrs supportedSystems (system: {
        default = mkEnv system;
      });
    };
}
