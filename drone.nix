{ ... }:

{
  # Override chrony to be the time reference
  services.chrony = {
    enable = true;
    extraConfig = ''
      driftfile /var/lib/chrony/drift
      allow all
      local stratum 1
      makestep 1.0 3
    '';
  };

  # Chrony needs the NTP port even with allowedUDPPorts configured below.
  networking.firewall.allowedUDPPorts = [ 123 ];
  networking.firewall.extraCommands = ''
    iptables -I INPUT -p udp --dport 123 -j ACCEPT
  '';
}
