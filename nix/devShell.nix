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
    pkgs.fontconfig.dev
    pkgs.freetype.dev
    pkgs.harfbuzz.dev
  ];
}
