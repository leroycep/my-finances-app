{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    zig-master = {
      url = "github:jessestricker/zig-master.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sqlite-zig = {
      url = "github:leroycep/sqlite-zig/sqlite-v3.37.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig-master,
    sqlite-zig
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
    packages.x86_64-linux.default = packages.x86_64-linux.my-finances-app;
    packages.x86_64-linux.my-finances-app = pkgs.stdenv.mkDerivation {
      pname = "my-finances-app";
      version = "dev";
      src = ./.;

      buildInputs = [
        sqlite-zig.packages.x86_64-linux.sqlite-zig
      ];

      nativeBuildInputs = [
        pkgs.zig
        sqlite-zig.packages.x86_64-linux.sqlite-zig
      ];

      buildPhase = ''
        zig build-lib ${sqlite-zig.packages.x86_64-linux.sqlite-zig}/sqlite.c -lc -static --global-cache-dir zig-global-cache
        zig build-exe src/main.zig ${sqlite-zig.packages.x86_64-linux.sqlite-zig}/sqlite.c -lc --pkg-begin sqlite3 ${sqlite-zig.packages.x86_64-linux.sqlite-zig}/sqlite3.zig --pkg-end -static --global-cache-dir zig-global-cache
      '';

      installPhase = ''
        mkdir -p $out/bin
        cp main $out/bin/my-finances-app
      '';
    };

    devShell.x86_64-linux = pkgs.mkShell {
      buildInputs = [
        pkgs.zig
        pkgs.zls
        pkgs.python3
        pkgs.python3Packages.ofxparse
        pkgs.sqlite
        sqlite-zig.packages.x86_64-linux.sqlite-zig
      ];
    };

    formatter.${system} = pkgs.alejandra;
  };
}
