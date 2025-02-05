{
  pkgs,
  zig,
  zls,
}:
pkgs.mkShell {
  nativeBuildInputs = [
    zig.master
    zls.default
    pkgs.sdl3.dev
  ];
}
