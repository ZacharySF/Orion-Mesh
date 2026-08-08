# Orion Mesh

Orion Mesh is a reproducible Raspberry Pi testbed for measuring how ROS 2 control traffic behaves when an H.264 stream competes for the same Wi-Fi channel on a BATMAN-adv network.

**Build two role-specific NixOS images, flash them to SD cards, and boot the Pis. The nodes configure and discover the mesh automatically—without a router or manually pairing peers.** The images also include the ROS 2 benchmark and its supporting tools.

The experiment itself starts deliberately from the ground node. It does not run automatically at boot, which keeps trial conditions and output under the operator's control.

## What the images configure

On every boot, the shared NixOS configuration:

1. puts `wlan0` into IBSS (ad hoc) mode;
2. joins the fixed `orion` wireless cell;
3. attaches `wlan0` to the BATMAN-adv interface `bat0`;
4. assigns a deterministic `10.23.X.Y/16` address derived from the Wi-Fi MAC address; and
5. installs ROS 2, CycloneDDS, chrony, ffmpeg, and the Orion benchmark tools.

Any compatible nodes using the same SSID, frequency, and BSSID can discover one another when they are within wireless range. The current experiment uses two nodes, so it measures contention on a shared wireless medium rather than multi-hop routing behavior.

> [!NOTE]
> Automatic mesh formation assumes that each Wi-Fi adapter and driver supports IBSS mode and that the adapter is exposed as `wlan0`, which the current services reference explicitly. The repository cannot add IBSS support to incompatible hardware or automatically select a differently named interface.

## Project status

The experiment has been completed, data has been collected, and a paper has been written. The paper and dataset are not published in this repository yet, so this version focuses on the reproducible system configuration and measurement tooling rather than presenting the results.

## Experiment design

The drone node publishes `geometry_msgs/TwistStamped` messages at 50 Hz while transmitting synthetic H.264 video. During the overlapping portion of each run, the ground node receives both streams and records one-way control-message latency, the population standard deviation of that latency, internal sequence gaps, and CPU utilization.

| Item | Configuration |
| --- | --- |
| Independent variable | Configured H.264 bitrate: 0, 1, 2, 4, 6, 8, 10, 12, and 15 Mbps |
| Control traffic | `TwistStamped` at 50 Hz |
| ROS 2 middleware | CycloneDDS |
| Network | BATMAN-adv over an IBSS Wi-Fi link |
| Primary measurements | Mean, median, p95, p99, and maximum one-way latency |
| Other measurements | Population standard deviation of latency, internal observed sequence-gap loss, and CPU utilization |

Each control message carries its send timestamp and a sequence number. The subscriber compares that timestamp with its local receive time. Its loss metric counts gaps between the minimum and maximum sequence numbers received; it cannot count losses before the first or after the last received message, and its `packets_sent` value is an inferred sequence span rather than the publisher's actual count.

One-way latency is only meaningful when the node clocks agree. Chrony provides clock synchronization, and its measured offset should be checked before every collection run.

## From source to a running mesh

### 1. Configure access and clock synchronization

The public configuration intentionally locks the `ground` account with `hashedPassword = "!";`. Before building an image you intend to operate remotely:

- add the required SSH public keys through a private configuration;
- provide a password hash if you want to use password-protected `sudo` commands such as `mesh-status`;
- keep private keys and real password hashes out of this repository; and
- update the drone address in `ground.nix` if your drone node does not use the configured `10.23.212.203` address.

The ground node also needs the matching private key for a public key authorized on the drone, and the drone host key must already be accepted or provisioned in the ground node's `known_hosts`. The public image provisions neither. Because the account is locked, `ssh-copy-id` cannot bootstrap this through password login unless you temporarily provide a password hash through private configuration. Establish and verify noninteractive ground-to-drone SSH before collecting data; `orion-run_trial` checks it with `BatchMode=yes`.

### 2. Build the role-specific SD images

Build on an `aarch64-linux` host or with an aarch64-capable Nix builder configured.

```bash
git clone https://github.com/ZacharySF/Orion-Mesh.git
cd Orion-Mesh

# Raspberry Pi 4 drone node
nix build .#nixosConfigurations.drone.config.system.build.sdImage -o result-drone

# Raspberry Pi 3 ground node
nix build .#nixosConfigurations.ground.config.system.build.sdImage -o result-ground
```

The compressed images are written under `result-drone/sd-image/` and `result-ground/sd-image/`. Decompress each `.img.zst` file, then select the resulting `.img` as a custom image in Raspberry Pi Imager. Flash the drone and ground images to their respective SD cards.

### 3. Boot and verify the mesh

The mesh starts automatically. On either node:

```bash
mesh-status
batctl n
ip addr show bat0
```

`mesh-status` reports the generated hostname and mesh address, the IBSS link, BATMAN-adv interfaces, and visible neighbors. Test end-to-end reachability with the address reported by the other node:

```bash
ping <other-node-bat0-ip>
```

### 4. Verify clock synchronization

On the ground node:

```bash
chronyc tracking
chronyc sources -v
```

Do not collect one-way latency measurements until the reported clock offset is acceptable for the experiment.

## Run the benchmark

The SD images already contain the packaged benchmark; a separate colcon build is not required after flashing.

Run one baseline trial with no video:

```bash
orion-run_trial --drone <drone-bat0-ip> --bitrate 0 --trial 1
```

Run a trial with a 4 Mbps encoder target:

```bash
orion-run_trial --drone <drone-bat0-ip> --bitrate 4 --trial 2
```

Run the complete configured bitrate sweep:

```bash
orion-run_batch --drone <drone-bat0-ip> --repeats 5 --cooldown 30
```

The batch runner writes `summary.csv`. Each trial directory contains:

- `trial_NNN_brX_results.json` — trial-level metrics;
- `trial_NNN_brX_raw.csv` — per-message sequence numbers and latency;
- `cpu.csv` — CPU utilization samples;
- `cpu_stdout.log` — CPU monitor output;
- `sub_output.log` — subscriber output; and
- `video_rx.log` — receiver output for nonzero-bitrate trials only.

The drone-side publisher and video-transmitter logs remain on the drone at `/tmp/orion_control_pub.log` and `/tmp/orion_video_tx.log`; the runner does not copy them into the trial directory. Baseline trials do not produce an ffmpeg receiver log.

## Repository map

| Path | Purpose |
| --- | --- |
| `flake.nix` | NixOS flake, role-specific SD images, and development shell |
| `pi-config.nix` | Shared boot, mesh, addressing, SSH, and user configuration |
| `drone.nix` | Drone-node chrony reference configuration |
| `ground.nix` | Ground-node clock synchronization configuration |
| `ros2.nix` | ROS 2, CycloneDDS, ffmpeg, chrony, and benchmark packages |
| `bench.nix` | Nix package for the Python nodes and experiment scripts |
| `orion_bench/orion_bench/` | Publisher, subscriber, QoS, and metric collection |
| `orion_bench/scripts/` | Video, CPU logging, single-trial, and batch orchestration |

## Design choices

- **Reliable control QoS:** Retransmission delay remains part of measured latency. The reported loss value represents only internal gaps in the observed sequence span despite reliable delivery.
- **High-entropy synthetic video:** Random image data avoids the unrealistically low traffic produced when a static test pattern compresses too easily.
- **Declarative node images:** NixOS keeps the operating system, mesh configuration, middleware, and benchmark tools consistent across both Pis.
- **Role separation:** Shared configuration lives in `pi-config.nix`; clock-reference behavior remains explicit in `drone.nix` and `ground.nix`.

## Measurement limits

- The public repository does not yet include the collected dataset or paper.
- A two-node BATMAN-adv link does not exercise multi-hop route selection.
- One-way latency remains sensitive to residual clock-synchronization error.
- The reported `jitter_ms` value is `numpy.std` over one-way latency, not inter-arrival jitter or packet-delay variation.
- Loss before the first received sequence number or after the last received sequence number is not observable with the current subscriber calculation.
- The transmitter and publisher start before the subscriber and use the same nominal duration, so they stop before the subscriber's measurement window ends; the current run is not a full-duration overlap.
- The bitrate condition is the encoder target; the current result files do not independently record measured network throughput.
- The publisher generates synthetic control values rather than commands from a flight controller.
