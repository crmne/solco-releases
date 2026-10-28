# Solco's official Linux build, unchanged: the release's portable archive,
# with its libraries pointed at Nix's. nix/release.json names the archive and
# its hash; the release automation updates it with each release.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  alsa-lib,
  dbus,
  libGL,
  libX11,
  libXcursor,
  libXi,
  libxkbcommon,
  openssl,
  pipewire,
  vulkan-loader,
  wayland,
  release ? lib.importJSON ./release.json,
}:

let
  system = stdenv.hostPlatform.system;
  source = release.sources.${system} or (throw "Solco has no Linux build for ${system}");
in
stdenv.mkDerivation {
  pname = "solco";
  inherit (release) version;

  src = fetchurl { inherit (source) url hash; };

  nativeBuildInputs = [ autoPatchelfHook ];

  # Linked directly.
  buildInputs = [
    alsa-lib
    openssl
    pipewire
    stdenv.cc.cc.lib
  ];

  # Opened at run time: the window, graphics and the desktop's file pickers.
  runtimeDependencies = [
    dbus.lib
    libGL
    libX11
    libXcursor
    libXi
    libxkbcommon
    vulkan-loader
    wayland
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    # The program finds its analysis models and release details beside it.
    mkdir -p $out/lib $out/bin
    cp -r . $out/lib/solco
    # Desktop files are installed below; Nix, not Solco, updates this copy.
    rm -r $out/lib/solco/packaging
    rm -f $out/lib/solco/solco-portable.txt
    ln -s $out/lib/solco/solco $out/bin/solco

    install -Dm644 packaging/applications/solco.desktop $out/share/applications/solco.desktop
    install -Dm644 packaging/icons/solco.svg $out/share/icons/hicolor/scalable/apps/solco.svg
    for icon in packaging/icons/hicolor/*/apps/solco.png; do
      size=''${icon#packaging/icons/hicolor/}
      install -Dm644 $icon $out/share/icons/hicolor/''${size%%/*}/apps/solco.png
    done
    install -Dm644 LICENSE $out/share/licenses/solco/LICENSE

    runHook postInstall
  '';

  meta = {
    description = "Prep studio for DJs: grids, keys, tags, smart playlists and USB exports for CDJs";
    longDescription = ''
      Solco grids every track you add, keys it, hears its genre and character,
      fixes its tags and files it into smart playlists, then writes the USB
      drive your CDJs read. It is in private beta and needs a licence key
      from https://getsolco.com.
    '';
    homepage = "https://getsolco.com";
    downloadPage = "https://github.com/crmne/solco-releases/releases";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "solco";
  };
}
