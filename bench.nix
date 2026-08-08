{ pkgs, rosPackages }:

let
  python = pkgs.python3;

  # The key packages we need directly
  rosDeps = [
    rosPackages.ros-base
    rosPackages.rclpy
    rosPackages.rcl-interfaces
    rosPackages.geometry-msgs
    rosPackages.std-msgs
    rosPackages.builtin-interfaces
    rosPackages.rmw-cyclonedds-cpp
    python.pkgs.numpy
  ];

  # lib.closePropagation walks ALL propagatedBuildInputs recursively.
  # This is the same mechanism NixOS uses to build /run/current-system/sw.
  # It resolves rclpy -> rcl_interfaces -> rosidl_parser -> ... everything.
  fullClosure = pkgs.lib.closePropagation rosDeps;

  # Merge the entire closure into one environment with a single site-packages
  rosPythonEnv = pkgs.buildEnv {
    name = "orion-ros-python-env";
    paths = fullClosure;
    pathsToLink = [ "/lib" "/share" ];
    ignoreCollisions = true;
  };

in pkgs.stdenv.mkDerivation {
  pname = "orion-bench";
  version = "0.1.0";
  src = ./orion_bench;

  dontConfigure = true;
  dontBuild = true;
  dontFixup = false;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/lib/python
    cp -r orion_bench $out/lib/python/

    mkdir -p $out/bin

    for mod in control_pub control_sub; do
      makeWrapper ${python}/bin/python3 $out/bin/$mod \
        --prefix PYTHONPATH : "$out/lib/python" \
        --prefix PYTHONPATH : "${rosPythonEnv}/lib/${python.libPrefix}/site-packages" \
        --prefix LD_LIBRARY_PATH : "${rosPythonEnv}/lib" \
        --prefix AMENT_PREFIX_PATH : "${rosPythonEnv}" \
        --add-flags "-m orion_bench.$mod"
    done

    for f in scripts/*.sh; do
      name="$(basename "$f" .sh)"
      install -m755 "$f" "$out/bin/orion-$name"
    done
  '';

  meta = {
    description = "ROS 2 control-message latency bench for Orion mesh experiments";
    license = pkgs.lib.licenses.mit;
  };
}
