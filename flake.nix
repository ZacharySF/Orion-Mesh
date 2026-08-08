{
  description = "Orion mesh: ROS 2 control-message latency under H.264 video load";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-ros-overlay = {
      url = "github:lopsided98/nix-ros-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [ "https://ros.cachix.org" ];
    extra-trusted-public-keys = [
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };

  outputs = { self, nixpkgs, nix-ros-overlay, ... }: let
    # Shared modules for both Pis
    sharedModules = [
      "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

      { nixpkgs.overlays = [
        (final: prev: { vcstool = prev.vcs2l or prev.emptyDirectory; })
        nix-ros-overlay.overlays.default
      ]; }
      ./pi-config.nix
      ./ros2.nix

      ({ lib, ... }: {
        sdImage.compressImage = true;
        boot.supportedFilesystems.zfs = lib.mkForce false;
        fileSystems."/" = lib.mkForce {
          device = "/dev/disk/by-label/NIXOS_SD";
          fsType = "ext4";
        };
      })
    ];
  in {

    # nix build .#drone   (Pi 4 image)
    nixosConfigurations.drone = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = sharedModules ++ [ ./drone.nix ];
    };

    # nix build .#ground  (Pi 3 image)
    nixosConfigurations.ground = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = sharedModules ++ [ ./ground.nix ];
    };

    # Development shell for building orion_bench with colcon
    devShells.aarch64-linux.default = let
      pkgs = import nixpkgs {
        system = "aarch64-linux";
        overlays = [ nix-ros-overlay.overlays.default ];
      };
      rosPackages = pkgs.rosPackages.jazzy;
    in pkgs.mkShell {
      name = "orion-bench-dev";
      packages = (with rosPackages; [
        ros-base
        rmw-cyclonedds-cpp
        geometry-msgs
        ros2cli
        ros2topic
      ]) ++ (with pkgs; [
        ffmpeg-full
        chrony
        python3Packages.numpy
        python3Packages.colcon-common-extensions
      ]);

      shellHook = ''
        export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
        export ROS_DOMAIN_ID=42
        echo "Orion bench dev shell. Run: colcon build --packages-select orion_bench"
      '';
    };
  };
}
