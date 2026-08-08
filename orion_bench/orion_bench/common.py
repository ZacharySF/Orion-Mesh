"""Shared constants and helpers for the Orion control-message bench."""

import struct
import time

from rclpy.qos import (
    QoSProfile,
    QoSReliabilityPolicy,
    QoSHistoryPolicy,
    QoSDurabilityPolicy,
)

# ── Topics ──────────────────────────────────────────────────────────────────

TOPIC_CONTROL = '/orion/control'

# ── QoS ─────────────────────────────────────────────────────────────────────
# Default: RELIABLE + VOLATILE.  Control messages should not be dropped
# silently — we *want* DDS to attempt retransmission so we can measure
# the actual delivery performance (including retransmit-induced latency).
# Packet "loss" in our experiment = messages that never arrived within
# the trial window despite DDS reliability.

QOS_CONTROL = QoSProfile(
    reliability=QoSReliabilityPolicy.RELIABLE,
    durability=QoSDurabilityPolicy.VOLATILE,
    history=QoSHistoryPolicy.KEEP_LAST,
    depth=10,
)

# Best-effort variant for comparison runs
QOS_BEST_EFFORT = QoSProfile(
    reliability=QoSReliabilityPolicy.BEST_EFFORT,
    durability=QoSDurabilityPolicy.VOLATILE,
    history=QoSHistoryPolicy.KEEP_LAST,
    depth=1,
)


def get_qos(reliable: bool = True) -> QoSProfile:
    return QOS_CONTROL if reliable else QOS_BEST_EFFORT


# ── Clock helpers ──────────────────────────────────────────────────────────

def stamp_to_sec(stamp) -> float:
    """Convert builtin_interfaces/Time → float seconds."""
    return stamp.sec + stamp.nanosec * 1e-9
