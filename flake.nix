{
  description = "Solco, the prep studio for DJs (official Linux builds)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              # Solco is proprietary. This flake allows it, and only it, so
              # `nix run github:crmne/solco-releases` works without
              # NIXPKGS_ALLOW_UNFREE. The overlay leaves that to your config.
              config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "solco";
            }
          )
        );
    in
    {
      packages = forAllSystems (pkgs: rec {
        solco = pkgs.callPackage ./nix/package.nix { };
        default = solco;
      });

      overlays.default = final: _prev: {
        solco = final.callPackage ./nix/package.nix { };
      };
    };
}
