"""Shared constants and helpers for the Orion control-message bench."""

import struct
import time

from rclpy.qos import (
    QoSProfile,
    QoSReliabilityPolicy,
    QoSHistoryPolicy,
    QoSDurabilityPolicy,
)

# ROS topics used by both nodes

TOPIC_CONTROL = '/orion/control'

# QoS
# Default: RELIABLE + VOLATILE. DDS retransmission delay remains part of the
# latency measurement. The subscriber's loss estimate counts internal sequence
# gaps in the range it receives; it cannot see missing messages outside that
# range.

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


# Clock conversion

def stamp_to_sec(stamp) -> float:
    """Convert builtin_interfaces/Time to seconds."""
    return stamp.sec + stamp.nanosec * 1e-9
