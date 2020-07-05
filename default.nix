{ chan ? "e1843646b04fb564abf6330a9432a76df3269d2f"
, compiler ? "ghc864"
, withHoogle ? false
, doHoogle ? false
, doHaddock ? false
, enableLibraryProfiling ? false
, enableExecutableProfiling ? false
, strictDeps ? false
, isJS ? false
, asShell ? false
}:
let


  # It's a shpadoinkle day
  shpadoinkle = builtins.fetchGit {
    url    = https://gitlab.com/fresheyeball/Shpadoinkle.git;
    rev    = "5e0d0d2fcdd2e7d35a1808a113f29bc74b63d356";
    ref    = "master";
  };


  # Additional ignore patterns to keep the Nix src clean
  ignorance = [
    "*.md"
    "figlet"
    "*.nix"
    "*.sh"
    "*.yml"
  ];


  # Get some utilities
  inherit (import (shpadoinkle + "/nix/util.nix") { inherit compiler isJS; }) compilerjs gitignore;


  # Build faster by doing less
  chill = p: (pkgs.haskell.lib.overrideCabal p {
    inherit enableLibraryProfiling enableExecutableProfiling;
  }).overrideAttrs (_: {
    inherit doHoogle doHaddock strictDeps;
  });


  # Overlay containing Shpadoinkle packages, and needed alterations for those packages
  # as well as optimizations from Reflex Platform
  shpadoinkle-overlay =
    import (shpadoinkle + "/nix/overlay.nix") { inherit compiler isJS; };


  # Haskell specific overlay (for you to extend)
  haskell-overlay = hself: hsuper: { };


  # Top level overlay (for you to extend)
  Shpadoinkle-continuations-overlay = self: super: {
    haskell = super.haskell //
      { packages = super.haskell.packages //
        { ${compilerjs} = super.haskell.packages.${compilerjs}.override (old: {
            overrides = super.lib.composeExtensions (old.overrides or (_: _: {})) haskell-overlay;
          });
        };
      };
    };


  # Complete package set with overlays applied
  pkgs = import
    (builtins.fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/${chan}.tar.gz";
    }) {
    overlays = [
      shpadoinkle-overlay
      Shpadoinkle-continuations-overlay
    ];
  };


  # We can name him George
  Shpadoinkle-continuations = pkgs.haskell.packages.${compilerjs}.callCabal2nix "Shpadoinkle-continuations" (gitignore ignorance ./.) {};


in with pkgs; with lib; with haskell.packages.${compiler};

  if inNixShell || asShell
  then shellFor {
    inherit withHoogle;
    packages = _: [Shpadoinkle-continuations];
    COMPILER = compilerjs;
    buildInputs = [ stylish-haskell cabal-install ghcid ];
    shellHook = ''
      ${lolcat}/bin/lolcat ${./figlet}
    '';
  } else chill Shpadoinkle-continuations
