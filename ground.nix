{ ... }:

{
  # Override chrony to sync from the drone
  services.chrony = {
    enable = true;
    extraConfig = ''
      driftfile /var/lib/chrony/drift
      server 10.23.212.203 iburst prefer
      makestep 1.0 3
    '';
  };
}
