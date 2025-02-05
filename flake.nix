{
  description = "The snappy terminal emulator";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zig-overlay.inputs.flake-utils.follows = "flake-utils";

    zls.url = "github:zigtools/zls";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
      zls,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        zig = zig-overlay.packages.${system};
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default = pkgs.callPackage ./nix/devShell.nix {
          inherit zig;
          zls = zls.packages.${system};
        };
      }
    );
}
