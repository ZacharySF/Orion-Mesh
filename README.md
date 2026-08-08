# Orion Mesh

Orion Mesh is a two-node Raspberry Pi testbed for studying what happens to ROS 2 control traffic when an H.264 stream shares the same Wi-Fi channel. Both nodes run NixOS and communicate over a BATMAN-adv mesh link.

The repository builds separate SD-card images for the drone and ground nodes. After boot, each Pi joins the same IBSS cell, attaches `wlan0` to `bat0`, and assigns itself a repeatable mesh address derived from its Wi-Fi MAC address. ROS 2, CycloneDDS, Chrony, ffmpeg, and the benchmark scripts are included in the images.

The mesh starts at boot. Trials do not; I start each run from the ground node so I can check the link and clock synchronization first.

## Project status

The experiment and analysis are complete. I am polishing the paper and will add it with the dataset. The current repository contains the NixOS configuration and measurement tooling used for collection.

## Experiment

The drone publishes `geometry_msgs/TwistStamped` messages at 50 Hz while sending synthetic H.264 video. The ground node records one-way message latency, sequence gaps, and CPU use during the overlapping part of each run.

| Variable | Configuration |
| --- | --- |
| H.264 target bitrate | 0, 1, 2, 4, 6, 8, 10, 12, and 15 Mbps |
| Control traffic | `TwistStamped` at 50 Hz |
| ROS 2 middleware | CycloneDDS |
| Network | BATMAN-adv over IBSS Wi-Fi |
| Latency statistics | mean, median, p95, p99, maximum, and population standard deviation |
| Other measurements | observed sequence gaps and CPU utilization |

Each message carries its send time and a sequence number. The subscriber compares that timestamp with its local receive time, so the node clocks need to agree. Chrony handles synchronization, but its reported offset still needs to be checked before collection.

The loss calculation only sees gaps between the first and last sequence numbers received. It cannot detect messages lost before the first sample or after the last one, and `packets_sent` is an inferred sequence span rather than the publisher's count.

## Before building

The public configuration locks the `ground` account with `hashedPassword = "!";`. Add access through a private Nix configuration before flashing an image you plan to operate remotely.

You will need to:

- add your SSH public key or a private password hash;
- keep private keys and password hashes out of this repository;
- set the drone address in `ground.nix` if it differs from the configured address;
- provision the ground node with the matching private key and the drone's host key; and
- verify noninteractive SSH from ground to drone.

`orion-run_trial` uses `BatchMode=yes`, so a password prompt or unknown host key will stop the run.

The Wi-Fi adapters and drivers must support IBSS mode. The current services also expect the interface to be named `wlan0`.

## Build the images

Build on an `aarch64-linux` host or use an aarch64-capable Nix builder.

```bash
git clone https://github.com/ZacharySF/Orion-Mesh.git
cd Orion-Mesh

# Raspberry Pi 4 drone node
nix build .#nixosConfigurations.drone.config.system.build.sdImage -o result-drone

# Raspberry Pi 3 ground node
nix build .#nixosConfigurations.ground.config.system.build.sdImage -o result-ground
```

The compressed images are written under `result-drone/sd-image/` and `result-ground/sd-image/`. Decompress each `.img.zst` file and flash the resulting `.img` with Raspberry Pi Imager.

## Check the mesh

On either node:

```bash
mesh-status
batctl n
ip addr show bat0
```

`mesh-status` prints the hostname, generated mesh address, IBSS link state, BATMAN-adv interfaces, and visible neighbors. Check reachability with the other node's `bat0` address:

```bash
ping <other-node-bat0-ip>
```

Then check the clocks from the ground node:

```bash
chronyc tracking
chronyc sources -v
```

Do not collect one-way latency measurements until the reported offset is acceptable for the experiment.

## Run a trial

The benchmark is packaged into both images, so it does not need a separate colcon build after flashing.

Baseline, with no video:

```bash
orion-run_trial --drone <drone-bat0-ip> --bitrate 0 --trial 1
```

One trial at a 4 Mbps encoder target:

```bash
orion-run_trial --drone <drone-bat0-ip> --bitrate 4 --trial 2
```

Full configured sweep:

```bash
orion-run_batch --drone <drone-bat0-ip> --repeats 5 --cooldown 30
```

The batch runner creates `summary.csv`. Each trial directory contains:

- `trial_NNN_brX_results.json`: trial-level metrics
- `trial_NNN_brX_raw.csv`: sequence numbers and per-message latency
- `cpu.csv`: CPU samples
- `cpu_stdout.log`: CPU monitor output
- `sub_output.log`: subscriber output
- `video_rx.log`: ffmpeg receiver output for nonzero-bitrate trials

The publisher and transmitter logs stay on the drone at `/tmp/orion_control_pub.log` and `/tmp/orion_video_tx.log`. Baseline trials do not create a video receiver log.

## Repository layout

| Path | Contents |
| --- | --- |
| `flake.nix` | flake outputs, role-specific images, and development shell |
| `pi-config.nix` | shared boot, mesh, addressing, SSH, and user configuration |
| `drone.nix` | drone-side Chrony reference configuration |
| `ground.nix` | ground-side clock synchronization configuration |
| `ros2.nix` | ROS 2, CycloneDDS, ffmpeg, Chrony, and benchmark packages |
| `bench.nix` | package definition for the Python nodes and shell scripts |
| `orion_bench/orion_bench/` | publisher, subscriber, QoS, and metrics code |
| `orion_bench/scripts/` | video, CPU logging, trial, and batch scripts |

## Notes on the measurements

- The current setup has two nodes. It measures contention on a shared wireless channel, not multihop route selection.
- Reliable ROS 2 QoS keeps retransmission delay in the latency measurement. The reported loss value still counts only internal gaps in the observed sequence span.
- The video source uses random image data because a static test pattern compressed far below the configured bitrate.
- `jitter_ms` is `numpy.std` over the one-way latency samples. It is not inter-arrival jitter or packet-delay variation.
- The transmitter and publisher start before the subscriber and use the same nominal duration. They therefore stop before the subscriber's measurement window ends.
- A bitrate condition is the ffmpeg encoder target. The result files do not independently record measured network throughput.
- The publisher sends synthetic control values rather than commands from a flight controller.
