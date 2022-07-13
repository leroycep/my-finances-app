{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    zig-master = {
      url = "github:jessestricker/zig-master.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig-master,
  }: let
    system = "x86_64-linux";

    zig-master-overlay = final: prev: {
      zig = zig-master.packages.${system}.zig;
    };

    zls-overlay = final: prev: {
      zls = prev.zls.overrideAttrs (old: rec {
        pname = "zls";
        version = "unstable-2022-07-13";

        src = prev.fetchFromGitHub {
          owner = "zigtools";
          repo = pname;
          rev = "c0668876f943a1be435d7728cd7c50e442feeb79";
          sha256 = "sha256-z2Jh4sB0cM1TkNilXjj8TaOe7uvo6uVTUnFLWJRJIak=";
          fetchSubmodules = true;
        };

        nativeBuildInputs = [prev.zig];

        preBuild = ''
          export HOME=$TMPDIR
        '';

        installPhase = ''
          zig build install -Drelease-safe -Dcpu=baseline -Ddata_version=master --prefix $out
        '';
      });
    };

    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        zig-master-overlay
        zls-overlay
      ];
    };
  in rec {
    devShell.x86_64-linux = pkgs.mkShell {
      buildInputs = [
        zig-master.packages.x86_64-linux.zig
        pkgs.zls
        nixpkgs.legacyPackages.x86_64-linux.python3
        nixpkgs.legacyPackages.x86_64-linux.python3Packages.ofxparse
      ];
    };

    formatter.${system} = pkgs.alejandra;
  };
}
