{
  pkgs,
  zig,
  zls,
}:
pkgs.mkShell {
  nativeBuildInputs = [
    pkgs.zig_0_14
    zls.default

    # Dependencies
    pkgs.fontconfig.dev
    pkgs.freetype.dev
    pkgs.harfbuzz.dev
    pkgs.utf8proc

    pkgs.xorg.libX11
    pkgs.xorg.libXrender
    pkgs.xorg.libXrandr
  ];
}
