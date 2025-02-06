{ pkgs }:
pkgs.stdenv.mkDerivation {
  name = "SDL3_ttf";
  version = "preview-3.1.0";

  src = fetchGit {
    url = "https://github.com/libsdl-org/SDL_ttf.git";
    ref = "preview-3.1.0";
    rev = "3d7b6efedd0d2c9cfc6ee0a18906550d6c98d07a";
  };

  nativeBuildInputs = [
    pkgs.cmake
  ];

  buildInputs = [
    pkgs.sdl3
    pkgs.freetype
    pkgs.harfbuzz
  ];

  installPhase = ''
    make install
    ${pkgs.sd}/bin/sd --string-mode '${"{prefix}//nix/store"}' '/nix/store' $(find $out -name '*.pc')
  '';
}
