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

          # nixpkgs wraps pwsh in a script that prefixes LD_LIBRARY_PATH with the
          # libraries .NET dlopens (icu, openssl, ...). Every child process
          # inherits it, and nix itself then loads a libcurl built against a
          # newer glibc and dies. glibc's dlopen searches the calling library's
          # RUNPATH, so appending the same directories there lets the wrapper set
          # telemetry vars only. Darwin keeps upstream: its wrapper sets
          # DYLD_FALLBACK_LIBRARY_PATH, which only applies when a library is not
          # found at its install name - nix binaries reference absolute paths.
          # See design/decisions/0014-pwsh-runpath-not-ld-library-path.md.
          patchPwsh = pkg:
            if pkgs.stdenv.hostPlatform.isLinux && pkgs.lib.getName pkg == "powershell"
            then pkg.overrideAttrs (old: {
              appendRunpaths = [ (pkgs.lib.makeLibraryPath old.buildInputs) ];
              # autoPatchelfHook runs after this hook's body, so only the wrapper
              # is rebuilt here; the RUNPATH goes through appendRunpaths.
              postFixup = (old.postFixup or "") + ''
                makeWrapper $out/share/powershell/.pwsh-wrapped $out/share/powershell/pwsh \
                  --inherit-argv0 \
                  --set POWERSHELL_TELEMETRY_OPTOUT 1 \
                  --set DOTNET_CLI_TELEMETRY_OPTOUT 1
                cp $out/share/powershell/pwsh $out/bin/pwsh
              '';
            })
            else pkg;

        in pkgs.buildEnv {
          name = "dev-env";
          paths = map (p: demote (patchPwsh p)) (basePkgs ++ initPkgs ++ scopePkgs ++ extraPkgs);
        };
    in
    {
      packages = nixpkgs.lib.genAttrs supportedSystems (system: {
        default = mkEnv system;
      });
    };
}
