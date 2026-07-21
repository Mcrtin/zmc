{
  pkgs,
  zig,
}:

let
  runtimeLibs = [
    (pkgs.lib.getLib pkgs.stdenv.cc.cc)

    ## LWJGL / Minecraft natives
    pkgs.glfw3-minecraft
    pkgs.openal

    ## OpenAL backends
    pkgs.alsa-lib
    pkgs.libjack2
    pkgs.libpulseaudio
    pkgs.pipewire

    ## OpenGL
    pkgs.libGL

    ## X11
    pkgs.libX11
    pkgs.libXcursor
    pkgs.libXext
    pkgs.libXrandr
    pkgs.libXxf86vm

    ## LWJGL / Oshi
    pkgs.udev

    ## VulkanMod / LWJGL Vulkan
    pkgs.vulkan-loader
  ];
in
pkgs.mkShell {
  name = "zmc-dev";

  packages = [
    zig
    pkgs.jdk25
  ];

  buildInputs = runtimeLibs;

  shellHook = ''
    export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath runtimeLibs}:$LD_LIBRARY_PATH
  '';
}
