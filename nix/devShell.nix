{
  pkgs,
  zig,
  zls,
}:
pkgs.mkShell {
  nativeBuildInputs = [
    zig.master
    zls.default

    # Dependencies
    pkgs.sdl3.dev
    (pkgs.callPackage ./SDL3_ttf.nix { inherit pkgs; })
    pkgs.fontconfig
  ];
}
