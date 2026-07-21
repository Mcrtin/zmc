{
  lib,
  stdenv,
  zig,

  makeWrapper,

  glfw3-minecraft,
  openal,

  alsa-lib,
  libjack2,
  libpulseaudio,
  pipewire,

  libGL,

  xorg,

  udev,
  vulkan-loader,

  jdk25,
}:

stdenv.mkDerivation {
  pname = "zmc";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = [
    zig
    makeWrapper
  ];

  buildInputs = [
    glfw3-minecraft
    openal

    alsa-lib
    libjack2
    libpulseaudio
    pipewire

    libGL

    xorg.libX11
    xorg.libXcursor
    xorg.libXext
    xorg.libXrandr
    xorg.libXxf86vm

    udev
    vulkan-loader
  ];

  buildPhase = ''
    zig build \
      -Doptimize=ReleaseFast
  '';

  installPhase = ''
    install -Dm755 zig-out/bin/zmc \
      $out/bin/zmc

    wrapProgram $out/bin/zmc \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          glfw3-minecraft
          openal
          alsa-lib
          libjack2
          libpulseaudio
          pipewire
          libGL
          xorg.libX11
          xorg.libXcursor
          xorg.libXext
          xorg.libXrandr
          xorg.libXxf86vm
          udev
          vulkan-loader
        ]
      } \
      --prefix PATH : ${lib.makeBinPath [ jdk25 ]}
  '';

  meta = {
    description = "A Minecraft launcher written in Zig";
    homepage = "https://github.com/yourname/zmc";
    license = lib.licenses.mit;
    mainProgram = "zmc";
  };
}
