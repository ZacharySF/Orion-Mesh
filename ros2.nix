{ config, lib, pkgs, ... }:

let
  rosPackages = pkgs.rosPackages.jazzy;

  orionBench = import ./bench.nix { inherit pkgs rosPackages; };

  cycloneDdsConfig = pkgs.writeText "cyclonedds-orion.xml" ''
    <CycloneDDS>
      <Domain>
        <General>
          <Interfaces>
            <NetworkInterface name="bat0" />
          </Interfaces>
          <MaxMessageSize>1452</MaxMessageSize>
          <FragmentSize>1300</FragmentSize>
        </General>
        <Discovery>
          <ParticipantIndex>auto</ParticipantIndex>
          <MaxAutoParticipantIndex>120</MaxAutoParticipantIndex>
        </Discovery>
        <Internal>
          <LeaseDuration>10s</LeaseDuration>
          <SocketReceiveBufferSize min="1MB" />
        </Internal>
        <Tracing>
          <Verbosity>warning</Verbosity>
          <OutputFile>stderr</OutputFile>
        </Tracing>
      </Domain>
    </CycloneDDS>
  '';
in
{
  environment.systemPackages = (with rosPackages; [
    ros-base
    rmw-cyclonedds-cpp
    geometry-msgs
    ros2cli
    ros2topic
    ros2bag
    ros2node
    ros2param
    cyclonedds
  ]) ++ (with pkgs; [
    # H.264 video load generation at controlled bitrates
    ffmpeg-full

    # Clock sync for one-way latency measurement
    chrony

    # Stats computation
    python3Packages.numpy

    # Orion experiment bench (control_pub, control_sub, trial scripts)
    orionBench
  ]);

  environment.variables = {
    RMW_IMPLEMENTATION = "rmw_cyclonedds_cpp";
    CYCLONEDDS_URI = "file://${cycloneDdsConfig}";
    ROS_DOMAIN_ID = "42";
    ROS_LOCALHOST_ONLY = "0";
  };

  # Chrony is configured per-role in drone.nix / ground.nix

  networking.firewall.allowedUDPPorts = [
    123    # NTP/chrony
    5004   # RTP video stream
    5005   # RTCP
  ];
}
