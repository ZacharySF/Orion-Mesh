{ config, lib, pkgs, ... }:

let
  orion = {
    # SAME ON ALL NODES
    ssid = "orion";
    freq = 2412; # channel 1 (must match on every node)
    bssid = "02:9a:42:f7:16:29"; # fixed BSSID for the IBSS cell
  };

  # Helper script to derive IP address from wlan0 MAC address
  # Hashes full MAC using SHA256 and derives two octets for 10.23.X.Y format
  # Takes different parts of hash for X and Y to maximize distribution
  # Result: IPs from 10.23.1.1 to 10.23.254.254 (64,516 combinations)
  # Collision probability: ~0.4% with 16 nodes, ~14.5% with 100 nodes, ~50% at 302 nodes
  macToIp = pkgs.writeShellScript "mac-to-ip" ''
    if [ ! -e /sys/class/net/wlan0/address ]; then
      echo "Error: wlan0 not found" >&2
      exit 1
    fi

    MAC=$(cat /sys/class/net/wlan0/address)

    # Hash the full MAC for better distribution
    HASH=$(echo -n "$MAC" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)

    # Derive third octet from first 8 hex chars of hash
    OCTET_3=$(( (16#''${HASH:0:8} % 254) + 1 ))

    # Derive fourth octet from next 8 hex chars of hash (independent distribution)
    OCTET_4=$(( (16#''${HASH:8:8} % 254) + 1 ))

    echo "10.23.$OCTET_3.$OCTET_4"
  '';
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  time.timeZone = "America/Chicago";
  # Hostname set dynamically at boot from wlan0 MAC (see set-mesh-hostname service)

  networking.networkmanager.enable = false;
  systemd.network.enable = true;

  networking.useDHCP = false;
  boot.kernelModules = [ "batman-adv" ];

  environment.systemPackages = with pkgs; [
    batctl
    iw
    iproute2
    tcpdump
    mtr
    micro
    fastfetch
    git
    tmux
    htop

    # User-friendly mesh control commands
    (pkgs.writeScriptBin "mesh-up" ''
      #!${pkgs.bash}/bin/bash
      # Self-sudo once to avoid multiple prompts
      if [ "$EUID" -ne 0 ]; then
        exec sudo "$0" "$@"
      fi

      echo "Starting Orion mesh..."
      systemctl start orion-mesh
      systemctl status orion-mesh --no-pager
    '')

    (pkgs.writeScriptBin "mesh-down" ''
      #!${pkgs.bash}/bin/bash
      # Self-sudo once to avoid multiple prompts
      if [ "$EUID" -ne 0 ]; then
        exec sudo "$0" "$@"
      fi

      echo "Stopping Orion mesh..."
      systemctl stop orion-mesh
      systemctl status orion-mesh --no-pager
    '')

    (pkgs.writeScriptBin "mesh-status" ''
      #!${pkgs.bash}/bin/bash
      # Self-sudo once at the top to avoid multiple password prompts
      if [ "$EUID" -ne 0 ]; then
        exec sudo "$0" "$@"
      fi

      # Get node info
      if [ -e /sys/class/net/wlan0/address ]; then
        MAC=$(cat /sys/class/net/wlan0/address)
        # Use same hash algorithm as macToIp
        HASH=$(echo -n "$MAC" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
        OCTET_3=$(( (16#''${HASH:0:8} % 254) + 1 ))
        OCTET_4=$(( (16#''${HASH:8:8} % 254) + 1 ))
        IP="10.23.$OCTET_3.$OCTET_4"
      else
        IP="unknown"
        MAC="unknown"
      fi
      HOSTNAME=$(hostname)

      echo "=== Node Identity ==="
      echo "Hostname: $HOSTNAME"
      echo "IP Address: $IP (derived from wlan0 MAC)"
      echo "wlan0 MAC: $MAC"
      echo ""
      echo "=== Orion Mesh Service Status ==="
      systemctl status orion-mesh --no-pager
      echo ""
      echo "=== IBSS Link State (wlan0) ==="
      ${pkgs.iw}/bin/iw dev wlan0 link || echo "wlan0 not joined to IBSS"
      echo ""
      echo "=== Batman Interfaces ==="
      ${pkgs.batctl}/bin/batctl if || echo "No batman interfaces"
      echo ""
      echo "=== Batman Neighbors ==="
      ${pkgs.batctl}/bin/batctl n || echo "No neighbors"
      echo ""
      echo "=== bat0 Status ==="
      ${pkgs.iproute2}/bin/ip addr show bat0 || echo "bat0 not up"
    '')
  ];

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      # Password auth enabled until you add SSH keys below
      # After adding keys to authorizedKeys, set this to false for security
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.ground = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    packages = with pkgs; [ tree ];

    # Never commit a real password hash to this public repository.
    # Replace this value privately before deployment, or configure SSH keys below.
    hashedPassword = "!";

    # SSH key setup (recommended for security):
    # 1. On your laptop, generate a key: ssh-keygen -t ed25519 -C "your_email@example.com"
    # 2. Copy ~/.ssh/id_ed25519.pub contents and paste below
    # 3. After verifying SSH key login works, disable PasswordAuthentication above
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... you@laptop"
    ];
  };

  # Automatic console login (sudo still requires password)
  services.getty.autologinUser = "ground";
  security.sudo.wheelNeedsPassword = true;

  # Show IP addresses at login so you can find the Pi headlessly
  environment.etc."profile.d/show-ips.sh".text = ''
    echo ""
    echo "=== Orion Node ==="
    echo "Hostname: $(hostname)"
    echo "eth0 IPs: $(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d./]+' | tr '\n' '  ')"
    echo "bat0 IPs: $(ip -4 addr show bat0 2>/dev/null | grep -oP 'inet \K[\d./]+' | tr '\n' '  ')"
    echo "================="
    echo ""
  '';

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  networking.firewall.allowedUDPPorts = [ 5353 ];
  networking.firewall.trustedInterfaces = [ "bat0" ];

  # Auto-configure hostname from wlan0 MAC address at boot
  systemd.services.set-mesh-hostname = {
    description = "Set Orion mesh hostname from wlan0 MAC (no hostnamectl)";
    wantedBy = [ "multi-user.target" ];
    after = [ "sys-subsystem-net-devices-wlan0.device" ];
    before = [ "avahi-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      IP=$(${macToIp})
      IFS=. read -r _ _ OCT3 OCT4 <<< "$IP"

      NEW_HOST="orion-$OCT3-$OCT4"
      ${pkgs.nettools}/bin/hostname "$NEW_HOST"

      echo "Hostname set to $NEW_HOST (derived from wlan0 MAC)"
    '';
  };

  systemd.network.netdevs."20-bat0" = {
    netdevConfig = {
      Name = "bat0";
      Kind = "batadv";
    };
  };

  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth* end* en*";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };

  # Assign a static IP to the wired ethernet interface.
  # Interface names vary by Pi model: eth0, end0, enu1u1, etc.
  # This discovers it dynamically by checking /sys/class/net/*/type.
  systemd.services.configure-eth-static = {
    description = "Add static fallback IP to ethernet from MAC";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" "network-pre.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Find the first wired ethernet interface (type 1 = ethernet)
      # Exclude lo, wlan*, bat*, veth*
      ETH=""
      for i in {1..30}; do
        for dev in /sys/class/net/*; do
          iface=$(basename "$dev")
          case "$iface" in
            lo|wlan*|bat*|veth*|docker*|br*) continue ;;
          esac
          # type 1 = ethernet (ARPHRD_ETHER)
          if [ -e "$dev/type" ] && [ "$(cat "$dev/type")" = "1" ] && [ -e "$dev/address" ]; then
            # Make sure it's not wireless
            if [ ! -d "$dev/wireless" ] && [ ! -d "$dev/phy80211" ]; then
              ETH="$iface"
              break 2
            fi
          fi
        done
        echo "Waiting for wired ethernet ($i/30)..."
        sleep 1
      done

      if [ -z "$ETH" ]; then
        echo "No wired ethernet found, skipping static IP"
        exit 0
      fi

      MAC=$(cat /sys/class/net/$ETH/address)
      HASH=$(echo -n "$MAC" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      OCTET=$(( (16#''${HASH:0:8} % 240) + 10 ))

      ${pkgs.iproute2}/bin/ip addr add "192.168.99.$OCTET/24" dev "$ETH" 2>/dev/null || true
      echo "Added static fallback 192.168.99.$OCTET/24 to $ETH (from MAC $MAC)"
    '';
  };

  systemd.network.networks."30-bat0" = {
    matchConfig.Name = "bat0";
    # IP address configured dynamically at boot (see configure-bat0-ip service)
    networkConfig = {
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    linkConfig.RequiredForOnline = "no";
  };

  # Keep wlan0 unmanaged by networkd (we handle it in orion-mesh service)
  systemd.network.networks."10-wlan0" = {
    matchConfig.Name = "wlan0";
    networkConfig = {
      LinkLocalAddressing = "no";
      # BatmanAdvanced removed to avoid race with IBSS join
    };
    linkConfig.RequiredForOnline = "no";
  };

  systemd.services.orion-mesh = {
    description = "Orion Mesh: IBSS and Batman-adv on wlan0 and bat0";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" "sys-subsystem-net-devices-wlan0.device" "sys-subsystem-net-devices-bat0.device" ];
    wants = [ "systemd-networkd.service" "sys-subsystem-net-devices-wlan0.device" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      ${pkgs.kmod}/bin/modprobe batman-adv || true

      # Wait for bat0 to be created by systemd-networkd (short timeout as fallback)
      for i in {1..10}; do
        if ${pkgs.iproute2}/bin/ip link show bat0 &>/dev/null; then
          break
        fi
        echo "Waiting for bat0 to be created ($i/10)..."
        sleep 0.5
      done

      # Leave the old cell before putting wlan0 into IBSS mode.
      ${pkgs.iproute2}/bin/ip link set wlan0 down || true
      ${pkgs.iw}/bin/iw dev wlan0 ibss leave 2>/dev/null || true
      ${pkgs.iw}/bin/iw dev wlan0 set type ibss || true
      ${pkgs.iproute2}/bin/ip link set wlan0 up

      # Join the shared IBSS cell with a fixed BSSID.
      ${pkgs.iw}/bin/iw dev wlan0 ibss join ${orion.ssid} ${toString orion.freq} fixed-freq ${orion.bssid}

      # Remove a stale attachment before adding wlan0 to batman-adv.
      ${pkgs.batctl}/bin/batctl if del wlan0 2>/dev/null || true
      ${pkgs.batctl}/bin/batctl if add wlan0

      # Bring up the BATMAN-adv interface.
      ${pkgs.iproute2}/bin/ip link set bat0 up || true

      echo "=== IBSS joined ==="
      ${pkgs.iw}/bin/iw dev wlan0 link || true
      echo "=== Batman interface added ==="
      ${pkgs.batctl}/bin/batctl if || true
    '';
    preStop = ''
      echo "Tearing down Orion mesh..."

      ${pkgs.batctl}/bin/batctl if del wlan0 2>/dev/null || true
      ${pkgs.iw}/bin/iw dev wlan0 ibss leave 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip link set bat0 down 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip link set wlan0 down 2>/dev/null || true
      ${pkgs.iw}/bin/iw dev wlan0 set type managed 2>/dev/null || true

      echo "Mesh torn down."
    '';
  };

  # Auto-configure bat0 IP address from wlan0 MAC address
  systemd.services.configure-bat0-ip = {
    description = "Configure bat0 IP from wlan0 MAC";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" "orion-mesh.service" ];
    wants = [ "systemd-networkd.service" "orion-mesh.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      IP=$(${macToIp})

      # Flush any existing addresses
      ${pkgs.iproute2}/bin/ip addr flush dev bat0 2>/dev/null || true

      # Add new address based on MAC-derived IP (using /16 subnet for larger address space)
      ${pkgs.iproute2}/bin/ip addr add $IP/16 dev bat0

      echo "Configured bat0 with IP $IP/16 (derived from wlan0 MAC)"
    '';
    preStop = ''
      ${pkgs.iproute2}/bin/ip addr flush dev bat0 2>/dev/null || true
    '';
  };

  system.stateVersion = "26.05";
}
