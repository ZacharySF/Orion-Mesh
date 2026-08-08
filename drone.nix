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

  # Force NTP port open — allowedUDPPorts alone wasn't working
  networking.firewall.allowedUDPPorts = [ 123 ];
  networking.firewall.extraCommands = ''
    iptables -I INPUT -p udp --dport 123 -j ACCEPT
  '';
}
