{
  description = "The snappy terminal emulator";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:mitchellh/zig-overlay/627055069ee1409e8c9be7bcc533e8823fb87b18";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zig-overlay.inputs.flake-utils.follows = "flake-utils";

    zls.url = "github:zigtools/zls/0.14.0";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    zls.inputs.zig-overlay.follows = "zig-overlay";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig-overlay,
      zls,
      ...
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
