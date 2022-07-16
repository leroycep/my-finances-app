{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
  };

  outputs = {
    self,
    nixpkgs
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
    };
  in rec {
    packages.x86_64-linux.default = packages.x86_64-linux.my-finances-app;
    packages.x86_64-linux.my-finances-app = pkgs.python3Packages.buildPythonApplication {
      pname = "my_finances_app";
      version = "0.0.1";
      src = ./.;
      format = "pyproject";

      propagatedBuildInputs = [
          (let
            my-python-packages = py-pkgs: [
              py-pkgs.ofxparse
            ];
          in
            pkgs.python3.withPackages my-python-packages)
      ];
    };

    formatter.${system} = pkgs.alejandra;
  };
}
