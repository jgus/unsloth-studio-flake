{
  description = "Unsloth Studio: AGPL-licensed CLI + web UI assembled from the unslothai/unsloth source tree.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib?ref=feat/pyproject-sibling-cascades";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    typer = {
      url = "github:jgus/typer-flake/v0.27.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    fastapi = {
      url = "github:jgus/fastapi-flake/v0.141.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    uvicorn = {
      url = "github:jgus/uvicorn-flake/v0.52.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    pydantic = {
      url = "github:jgus/pydantic-flake/v2.13.4";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    packaging = {
      url = "github:jgus/packaging-flake/v26.3";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    matplotlib = {
      url = "github:jgus/matplotlib-flake/v3.10.9";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    pandas = {
      url = "github:jgus/pandas-flake/v2.3.3";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    datasets = {
      url = "github:jgus/datasets-flake/v4.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    ddgs = {
      url = "github:jgus/ddgs-flake/v9.14.4";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    gguf = {
      url = "github:jgus/gguf-flake/v0.19.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    sqlite-vec = {
      url = "github:jgus/sqlite-vec-flake/v0.1.9";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    diffusers = {
      url = "github:jgus/diffusers-flake/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    transformers = {
      url = "github:jgus/transformers-flake/v5.5.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
    unsloth = {
      url = "github:jgus/unsloth-flake/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
  };

  outputs =
    { nixpkgs
    , flake-utils
    , flake-lib
    , typer
    , fastapi
    , uvicorn
    , pydantic
    , packaging
    , matplotlib
    , pandas
    , datasets
    , ddgs
    , gguf
    , sqlite-vec
    , diffusers
    , transformers
    , unsloth
    , ...
    }:
    let
      pin = import ./pin.nix;
      inherit (pin) version sourceRev sourceHash npmDepsHash;
      source = { type = "github"; owner = "unslothai"; repo = "unsloth"; };

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
          pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
            (pyfinal: pyprev:
              let
                packagingInput = packaging.packages.${final.system}.packaging;
                packagingForPython = final.lib.hiPrio (pyfinal.buildPythonPackage {
                  inherit (packagingInput) pname version src;
                  pyproject = true;
                  build-system = [ pyfinal.flit-core ];
                  doCheck = false;
                });
              in
              {
                cyclopts = pyprev.cyclopts.overridePythonAttrs (_: {
                  doCheck = false;
                  doInstallCheck = false;
                });
                pyarrow = pyprev.pyarrow.overridePythonAttrs (_: {
                  doCheck = false;
                  doInstallCheck = false;
                });
                sentence-transformers = pyprev.sentence-transformers.overridePythonAttrs (_: {
                  doCheck = false;
                  doInstallCheck = false;
                });
                xformers = pyprev.xformers.overridePythonAttrs (_: {
                  doCheck = false;
                  doInstallCheck = false;
                });
                unsloth-studio = ((pyfinal.callPackage ./pkgs/unsloth-studio {
                  inherit src version unsloth-studio-frontend;
                  dependencyOverrides.packaging = packagingForPython;
                }).overridePythonAttrs (oldAttrs: {
                  catchConflicts = false;
                  preInstallPhases = (oldAttrs.preInstallPhases or [ ]) ++ [ "preferPackagingForRuntimeDepsCheck" ];
                  preferPackagingForRuntimeDepsCheck = ''
                    export PYTHONPATH="${packagingForPython}/${pyfinal.python.sitePackages}:''${PYTHONPATH}"
                  '';
                })).overrideAttrs (oldAttrs: {
                  passthru = oldAttrs.passthru // {
                    requiredPythonModules =
                      [ packagingForPython ]
                        ++ final.lib.filter
                        (module: (module.pname or null) != "packaging")
                        oldAttrs.passthru.requiredPythonModules;
                  };
                });
              })
          ];
        };

      composedOverlay = nixpkgs.lib.composeManyExtensions [
        typer.overlays.default
        fastapi.overlays.default
        uvicorn.overlays.default
        pydantic.overlays.default
        matplotlib.overlays.default
        pandas.overlays.default
        datasets.overlays.default
        ddgs.overlays.default
        gguf.overlays.default
        sqlite-vec.overlays.default
        diffusers.overlays.default
        transformers.overlays.default
        unsloth.overlays.default
        overlay
      ];
    in
    flake-utils.lib.eachDefaultSystem
      (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ composedOverlay ];
        };
        regenArtifacts = pkgs.writeShellApplication {
          name = "regen-artifacts";
          runtimeInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.gh
            pkgs.jq
            pkgs.moreutils
            pkgs.prefetch-npm-deps
            (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
          ];
          text = ''exec ${pkgs.lib.getExe pkgs.bash} ${./regen-artifacts.sh}'';
        };
        pyprojectSibling = reqName: {
          inherit reqName;
          pypiName = reqName;
          flakeRepo = "jgus/${reqName}-flake";
          reqFile = "pyproject.toml";
          reqFormat = "pyproject";
          reqGroups = [ "studio" "huggingfacenotorch" ];
        };
        studioRequirementsSibling = reqName: {
          inherit reqName;
          pypiName = reqName;
          flakeRepo = "jgus/${reqName}-flake";
          reqFile = "studio/backend/requirements/studio.txt";
          mode = "exact";
        };
      in
      {
        packages = {
          inherit (pkgs) unsloth-studio-frontend;
          inherit (pkgs.python313.pkgs) unsloth-studio;
          update-version = flake-lib.lib.mkUpdateVersion {
            inherit pkgs source;
            buildAttr = "unsloth-studio";
            extraHashes = [ "npmDepsHash" ];
            artifactHook = pkgs.lib.getExe regenArtifacts;
            siblings =
              map pyprojectSibling [
                "typer"
                "fastapi"
                "uvicorn"
                "pydantic"
                "packaging"
                "datasets"
                "ddgs"
                "gguf"
                "sqlite-vec"
                "diffusers"
                "transformers"
              ]
              ++ map studioRequirementsSibling [ "matplotlib" "pandas" ];
          };
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            pinSchema = "github-npm";
            branchOwnedFiles = [
              "flake.nix"
              "pin.nix"
              "flake.lock"
              "pkgs/unsloth-studio-frontend"
              "pkgs/unsloth-studio/upstream-deps.nix"
            ];
            versionCanon = [ ''s/^0\.1\.([0-9]{2})([0-9])-beta$/0.1.\1.\2-beta/'' ];
          };
          default = pkgs.python313.pkgs.unsloth-studio;
        };
      }) // {
      overlays.default = composedOverlay;
    };
}
