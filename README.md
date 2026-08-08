# Orion Mesh

Orion Mesh is the test harness for my AP Research experiment. I wanted to measure what happens to ROS 2 control traffic when an H.264 stream competes for the same Wi-Fi channel on a low-cost BATMAN-adv network.

The setup uses two Raspberry Pis running NixOS. The drone node publishes `geometry_msgs/TwistStamped` messages at 50 Hz while sending H.264 video. The ground node receives both streams and records control-message latency, jitter, packet loss, and CPU use.

## Project status

The repository contains the node configuration, ROS 2 package, and scripts needed to run the experiment. It does not include a result dataset or final analysis yet. Until those are added, this is experiment infrastructure rather than evidence for a conclusion.

## Experiment design

| Item | Configuration |
| --- | --- |
| Independent variable | Configured H.264 bitrate: 0, 1, 2, 4, 6, 8, 10, 12, and 15 Mbps |
| Control traffic | `TwistStamped` at 50 Hz |
| ROS 2 middleware | CycloneDDS |
| Network | BATMAN-adv over an IBSS Wi-Fi link |
| Primary measurements | Mean, median, p95, p99, and maximum one-way latency |
| Other measurements | Jitter, sequence-gap packet loss, and CPU use |

Each control message carries its send timestamp and a sequence number. The subscriber compares the send timestamp with its local receive time, then uses sequence gaps to estimate messages that did not arrive during the trial window.

One-way latency only means something when the two clocks agree. Chrony is part of the setup, and I check the measured offset before collecting data.

## Repository map

| Path | Purpose |
| --- | --- |
| `flake.nix` | NixOS flake and development shell |
| `pi-config.nix` | Shared Raspberry Pi network and user configuration |
| `drone.nix` | Drone-node settings |
| `ground.nix` | Ground-node settings |
| `ros2.nix` | ROS 2, CycloneDDS, ffmpeg, and chrony packages |
| `orion_bench/orion_bench/` | Publisher, subscriber, QoS settings, and metric collection |
| `orion_bench/scripts/` | Video, CPU logging, single-trial, and batch scripts |

## Build the nodes

The public configuration locks the `ground` account with `hashedPassword = "!";`. Add an SSH public key or provide the password hash through a private configuration before deploying it.

```bash
# Raspberry Pi 4 drone node
nix build .#nixosConfigurations.drone.config.system.build.sdImage

# Raspberry Pi 3 ground node
nix build .#nixosConfigurations.ground.config.system.build.sdImage
```

Build the ROS 2 package on each node:

```bash
nix develop
mkdir -p ~/ros2_ws/src
ln -s /path/to/orion_bench ~/ros2_ws/src/
cd ~/ros2_ws
colcon build --packages-select orion_bench
source install/setup.bash
```

Set up key-based access from the ground node to the drone:

```bash
ssh-keygen -t ed25519
ssh-copy-id ground@<drone-bat0-ip>
```

Configure chrony with the drone as the reference node, then check the offset:

```bash
chronyc tracking
```

## Run the benchmark

Run one baseline trial with no video:

```bash
cd orion_bench/scripts
./run_trial.sh --drone 10.23.X.Y --bitrate 0 --trial 1
```

Run a trial with a 4 Mbps encoder target:

```bash
./run_trial.sh --drone 10.23.X.Y --bitrate 4 --trial 2
```

Run every configured bitrate condition:

```bash
./run_batch.sh --drone 10.23.X.Y --repeats 5 --cooldown 30
```

The batch runner writes `summary.csv`. Each trial also produces:

- `trial_NNN_brX_results.json` with trial-level metrics
- `trial_NNN_brX_raw.csv` with per-message sequence numbers and latency
- `cpu.csv` with CPU samples
- ffmpeg and ROS 2 logs for troubleshooting

## Design choices

CycloneDDS uses reliable QoS for the main experiment. Retransmission delay therefore remains part of the measured latency. In this project, packet loss means a sequence number never arrived during the trial window despite reliable delivery.

The video generator uses random image data instead of a static test pattern. A static pattern compresses too easily and can produce much less traffic than the configured bitrate.

NixOS keeps the software and network configuration consistent between the two nodes. Node-specific settings stay in `drone.nix` and `ground.nix`.

## Limits of the current setup

- The repository has no measured dataset yet.
- A two-node BATMAN-adv link measures contention on a shared wireless medium, not multi-hop route behavior.
- One-way latency is sensitive to clock-sync error.
- The bitrate condition is the encoder target. The current result files do not record independently measured network throughput.
- The publisher generates synthetic control values rather than commands from a flight controller.
