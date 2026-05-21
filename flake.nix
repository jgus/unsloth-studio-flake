{
  description = "Unsloth Studio: AGPL-licensed CLI + web UI assembled from the unslothai/unsloth source tree.";

  inputs = {
    # Heavy AI deps (torch, vllm, bitsandbytes, flash-attn, xformers, …) live on unstable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Single source of truth for the upstream rev + the hashes that depend on it. Regenerate via `nix run .#update-version` from this directory.
      pin = import ./pin.nix;
      inherit (pin) version sourceRev sourceHash npmDepsHash;

      # Overlay is the package definition; the per-system `packages` output below just extracts it.
      overlay = final: prev:
        let
          src = final.fetchFromGitHub {
            owner = "unslothai";
            repo = "unsloth";
            rev = sourceRev;
            hash = sourceHash;
          };
          unsloth-studio-frontend = final.callPackage ./pkgs/unsloth-studio-frontend { inherit src version npmDepsHash; };
        in
        {
          inherit unsloth-studio-frontend;
          # Inject into the python3 scope so `python3.withPackages (ps: [ ps.unsloth-studio ])` works.
          python3 = prev.python3.override (old: {
            packageOverrides = nixpkgs.lib.composeExtensions
              (old.packageOverrides or (_: _: { }))
              (pyfinal: _pyprev: {
                unsloth-studio = pyfinal.callPackage ./pkgs/unsloth-studio {
                  inherit src version unsloth-studio-frontend;
                };
              });
          });
        };
    in
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ overlay ];
          };
        in
        {
          packages = {
            inherit (pkgs) unsloth-studio-frontend;
            inherit (pkgs.python3.pkgs) unsloth-studio;
            update-version = pkgs.writeShellApplication {
              name = "update-version";
              text = ''exec ${./update-version.sh} "$@"'';
            };
            update-branches = pkgs.writeShellApplication {
              name = "update-branches";
              text = ''exec ${./update-branches.sh} "$@"'';
            };
            default = pkgs.python3.pkgs.unsloth-studio;
          };
        }) // {
      overlays.default = overlay;
    };
}
