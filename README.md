# Orion Mesh — H.264 Video Load vs ROS 2 Control Message Latency

AP Research experiment: measuring the impact of H.264 video streaming on
ROS 2 DDS control-message delivery in a BATMAN-adv mesh network.

## What this measures

**Independent variable:** H.264 video bitrate (0, 1, 2, 4, 6, 8, 10, 12, 15 Mbps)

**Dependent variables:**
- Mean latency (ms)
- Median latency (ms)  
- 95th percentile latency (ms)
- 99th percentile latency (ms)
- Jitter / standard deviation (ms)
- Packet loss (%)
- CPU utilization (%)

The video stream is the *load*. The control messages are what we *measure*.
They run simultaneously over the same BATMAN-adv mesh on the same wireless
medium.

## Hardware

- Node A ("drone"): Raspberry Pi — publishes control messages + streams video
- Node B ("ground"): Raspberry Pi — subscribes to control + receives video
- Both running NixOS with identical declarative configs

## Structure

```
flake.nix                       # NixOS flake with nix-ros-overlay
pi-config.nix                   # IBSS + Batman-adv mesh config
ros2.nix                        # ROS 2, CycloneDDS, ffmpeg, chrony

orion_bench/                    # ROS 2 Python package
├── package.xml
├── setup.py / setup.cfg
├── orion_bench/
│   ├── common.py               # QoS profiles, topic names
│   ├── control_pub.py          # Publishes TwistStamped at 50 Hz
│   └── control_sub.py          # Subscribes, measures all DVs
└── scripts/
    ├── video_tx.sh             # ffmpeg H.264 stream at target bitrate
    ├── video_rx.sh             # Receives + sinks video (sustains load)
    ├── cpu_log.sh              # Samples CPU% during trial
    ├── run_trial.sh            # Orchestrates one trial (SSH to drone)
    └── run_batch.sh            # Runs all 9 bitrate conditions
```

## Setup

### 1. Build NixOS and flash both Pis

```bash
# Drone node (Pi 4):
nix build .#nixosConfigurations.drone.config.system.build.sdImage

# Ground station (Pi 3):
nix build .#nixosConfigurations.ground.config.system.build.sdImage
```

### 2. Build the bench package on both nodes

```bash
nix develop  # enters the dev shell

mkdir -p ~/ros2_ws/src
ln -s /path/to/orion_bench ~/ros2_ws/src/
cd ~/ros2_ws
colcon build --packages-select orion_bench
source install/setup.bash
```

### 3. Set up SSH key auth (ground → drone)

```bash
ssh-keygen -t ed25519
ssh-copy-id ground@<drone-bat0-ip>
```

### 4. Configure clock sync

On the drone (reference node), edit `/etc/chrony.conf`:
```
local stratum 1
```

On the ground station:
```
server <drone-bat0-ip> iburst prefer
```

Verify: `chronyc tracking` — want offset < 1ms.

## Running experiments

### Single trial

```bash
# On ground station:
cd orion_bench/scripts

# Baseline (no video):
./run_trial.sh --drone 10.23.X.Y --bitrate 0 --trial 1

# 4 Mbps video load:
./run_trial.sh --drone 10.23.X.Y --bitrate 4 --trial 2

# 15 Mbps video load:
./run_trial.sh --drone 10.23.X.Y --bitrate 15 --trial 3
```

### Full batch (all 9 conditions × N repeats)

```bash
./run_batch.sh --drone 10.23.X.Y --repeats 5 --cooldown 30
```

This runs 45 trials (~112 minutes) and produces `~/trials/summary.csv`.

### Manual mode (if SSH orchestration is awkward)

On the drone:
```bash
# Terminal 1: video
# Use a noise source (not testsrc) so libx264 can't compress it down below target bitrate.
ffmpeg -re \
    -f lavfi -i "nullsrc=size=1280x720:rate=30,geq=random(1)*255:128:128" \
    -c:v libx264 -b:v 4M -minrate 4M -maxrate 4M -bufsize 1M \
    -preset ultrafast -tune zerolatency -g 60 -t 120 -an \
    -f rtp "rtp://<ground-ip>:5004" -loglevel warning -stats

# Terminal 2: control publisher
ros2 run orion_bench control_pub --ros-args -p hz:=50 -p duration:=120
```

On the ground:
```bash
# Terminal 1: video receiver
ffmpeg -protocol_whitelist file,udp,rtp -i rx.sdp -f null /dev/null

# Terminal 2: control subscriber
ros2 run orion_bench control_sub --ros-args \
    -p duration:=120 -p bitrate_label:=4 -p trial_id:=1 \
    -p out_dir:=~/trials

# Terminal 3: CPU monitor
./cpu_log.sh --duration 120 --out ~/trials/cpu.csv
```

## Output format

Each trial produces:

- `trial_NNN_brX_results.json` — structured metrics (all DVs)
- `trial_NNN_brX_raw.csv` — per-message seq + latency for external analysis
- `cpu.csv` — per-second CPU utilization

The batch runner merges all trial JSONs into `summary.csv` for import
into SPSS, R, or Python for Kruskal-Wallis / Mann-Whitney analysis.

## Notes

- **CycloneDDS** is used over FastDDS because it handles mesh topologies better.
  Fragment size is tuned to 1300 bytes to fit within typical Wi-Fi MTU.
- **Control messages** are `geometry_msgs/TwistStamped` — a real drone control
  type. Sequence numbers are embedded in `header.frame_id` for drop detection.
- **QoS is RELIABLE** by default. DDS will attempt retransmission, so measured
  latency includes retransmit delay. Packet "loss" means messages that never
  arrived within the trial window despite reliability.
- **Reproducibility**: NixOS declarative configs mean identical environments
  across nodes and across experiment sessions.
