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
    pkgs.fontconfig.dev
    pkgs.freetype.dev
    pkgs.harfbuzz.dev
    pkgs.utf8proc

    pkgs.xorg.libX11.dev
    pkgs.xorg.libXrender.dev
    pkgs.xorg.libXft.dev
    pkgs.xorg.libxcb.dev
  ];
}
