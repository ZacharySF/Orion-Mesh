"""
Receive ROS 2 control messages and record latency statistics.

Records per-message latency and writes both raw samples and a trial summary.

Dependent variables measured:
  - Mean latency (ms)
  - Median latency (ms)
  - 95th percentile latency (ms)
  - 99th percentile latency (ms)
  - Maximum latency (ms)
  - Jitter / std deviation (ms)
  - Packet loss (%)

Usage:
    ros2 run orion_bench control_sub
    ros2 run orion_bench control_sub --ros-args \
        -p reliable:=true -p duration:=120 \
        -p bitrate_label:=4 -p trial_id:=7 \
        -p out_dir:=/home/ground/trials
"""

import os
import json
import time

import numpy as np
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import TwistStamped

from . import common


class ControlSubscriber(Node):

    def __init__(self):
        super().__init__('control_sub')

        # Runtime parameters
        self.declare_parameter('reliable', True)
        self.declare_parameter('duration', 0)       # 0 = run until Ctrl-C
        self.declare_parameter('bitrate_label', 0)   # target bitrate label in Mbps
        self.declare_parameter('trial_id', 0)
        self.declare_parameter('out_dir', '')         # save trial results here
        self.declare_parameter('live_interval', 100)  # print live stats every N msgs

        reliable       = self.get_parameter('reliable').value
        self._duration = self.get_parameter('duration').value
        self._bitrate  = self.get_parameter('bitrate_label').value
        self._trial_id = self.get_parameter('trial_id').value
        self._out_dir  = self.get_parameter('out_dir').value
        self._live_n   = self.get_parameter('live_interval').value

        qos = common.get_qos(reliable)
        self._sub = self.create_subscription(
            TwistStamped, common.TOPIC_CONTROL, self._on_msg, qos
        )

        # Samples collected during this run
        self._latencies: list[float] = []   # ms
        self._seqs: list[int] = []
        self._recv_count = 0
        self._start_mono = time.monotonic()
        self._start_wall = time.time()

        # Duration watchdog
        if self._duration > 0:
            self._watchdog = self.create_timer(1.0, self._check_duration)

        self.get_logger().info(
            f"Listening on {common.TOPIC_CONTROL}  "
            f"QoS={'RELIABLE' if reliable else 'BEST_EFFORT'}  "
            f"bitrate_label={self._bitrate} Mbps  trial={self._trial_id}  "
            f"duration={'∞' if self._duration <= 0 else f'{self._duration}s'}"
        )

    def _check_duration(self):
        if time.monotonic() - self._start_mono >= self._duration:
            self.get_logger().info(f"Duration reached ({self._duration}s). Stopping.")
            raise SystemExit(0)

    def _on_msg(self, msg: TwistStamped):
        recv_wall = time.time()

        # One-way latency (requires chrony sync)
        send_sec = common.stamp_to_sec(msg.header.stamp)
        latency_ms = (recv_wall - send_sec) * 1000.0

        # Sequence
        try:
            seq = int(msg.header.frame_id)
        except ValueError:
            seq = -1

        self._latencies.append(latency_ms)
        self._seqs.append(seq)
        self._recv_count += 1

        # Live progress
        if self._recv_count % self._live_n == 0:
            recent = self._latencies[-self._live_n:]
            arr = np.array(recent)
            print(
                f"  [{self._recv_count:>6d} rx]  "
                f"last {self._live_n}: "
                f"avg={arr.mean():.2f}  "
                f"med={np.median(arr):.2f}  "
                f"p95={np.percentile(arr, 95):.2f}  "
                f"max={arr.max():.2f} ms"
            )

    # Trial summary

    def compute_results(self) -> dict:
        """Compute all dependent variables for this trial."""
        elapsed = time.monotonic() - self._start_mono

        if not self._latencies:
            return {'error': 'no messages received'}

        arr = np.array(self._latencies)

        # Packet loss from sequence gaps
        if self._seqs:
            valid_seqs = [s for s in self._seqs if s >= 0]
            if len(valid_seqs) >= 2:
                seq_min = min(valid_seqs)
                seq_max = max(valid_seqs)
                expected = seq_max - seq_min + 1
                received = len(valid_seqs)
                loss_pct = max(0.0, (1.0 - received / expected) * 100.0)
                packets_sent = expected
            else:
                packets_sent = len(self._latencies)
                loss_pct = 0.0
        else:
            packets_sent = len(self._latencies)
            loss_pct = 0.0

        results = {
            'trial_id':           self._trial_id,
            'bitrate_target_mbps': self._bitrate,
            'duration_s':         round(elapsed, 2),
            'packets_sent':       int(packets_sent),
            'packets_received':   int(self._recv_count),
            'packet_loss_pct':    round(loss_pct, 4),
            'mean_latency_ms':    round(float(arr.mean()), 4),
            'median_latency_ms':  round(float(np.median(arr)), 4),
            'p95_latency_ms':     round(float(np.percentile(arr, 95)), 4),
            'p99_latency_ms':     round(float(np.percentile(arr, 99)), 4),
            'max_latency_ms':     round(float(arr.max()), 4),
            'jitter_ms':          round(float(arr.std()), 4),
            'timestamp':          self._start_wall,
        }

        return results

    def print_report(self, results: dict):
        """Pretty-print the trial report to terminal."""
        print("\n" + "=" * 68)
        print(f"  TRIAL {results.get('trial_id', '?')}  |  "
              f"Target bitrate: {results.get('bitrate_target_mbps', '?')} Mbps")
        print("=" * 68)
        print(f"  Duration:          {results.get('duration_s', 0):.1f} s")
        print(f"  Packets sent:      {results.get('packets_sent', 0)}")
        print(f"  Packets received:  {results.get('packets_received', 0)}")
        print(f"  Packet loss:       {results.get('packet_loss_pct', 0):.2f}%")
        print(f"  ---")
        print(f"  Mean latency:      {results.get('mean_latency_ms', 0):.3f} ms")
        print(f"  Median latency:    {results.get('median_latency_ms', 0):.3f} ms")
        print(f"  P95 latency:       {results.get('p95_latency_ms', 0):.3f} ms")
        print(f"  P99 latency:       {results.get('p99_latency_ms', 0):.3f} ms")
        print(f"  Max latency:       {results.get('max_latency_ms', 0):.3f} ms")
        print(f"  Jitter (σ):        {results.get('jitter_ms', 0):.3f} ms")
        print("=" * 68)

        # ASCII histogram
        if self._latencies:
            self._print_histogram(np.array(self._latencies))

    def _print_histogram(self, arr: np.ndarray, bins: int = 12):
        counts, edges = np.histogram(arr, bins=bins)
        max_count = max(counts.max(), 1)
        bar_w = 35

        print("\n  Latency distribution:")
        for i, count in enumerate(counts):
            lo, hi = edges[i], edges[i + 1]
            bar_len = int(count / max_count * bar_w)
            bar = '█' * bar_len
            print(f"    {lo:8.2f}–{hi:8.2f} ms │{bar:<{bar_w}} {count}")
        print()

    def save_results(self, results: dict):
        """Save trial results as JSON + raw latencies as CSV."""
        if not self._out_dir:
            return

        os.makedirs(self._out_dir, exist_ok=True)

        tag = f"trial_{results['trial_id']:03d}_br{results['bitrate_target_mbps']}"

        # Structured results (one JSON per trial)
        json_path = os.path.join(self._out_dir, f"{tag}_results.json")
        with open(json_path, 'w') as f:
            json.dump(results, f, indent=2)
        print(f"  Saved results: {json_path}")

        # Raw per-message latencies (for external analysis)
        csv_path = os.path.join(self._out_dir, f"{tag}_raw.csv")
        with open(csv_path, 'w') as f:
            f.write("seq,latency_ms\n")
            for seq, lat in zip(self._seqs, self._latencies):
                f.write(f"{seq},{lat:.4f}\n")
        print(f"  Saved raw data: {csv_path}")


def main(args=None):
    rclpy.init(args=args)
    node = ControlSubscriber()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        results = node.compute_results()
        node.print_report(results)
        node.save_results(results)
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
