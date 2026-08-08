"""
Publish timestamped ROS 2 control messages at a fixed rate.

Sends geometry_msgs/TwistStamped at ~50 Hz (configurable).  Each message
carries the publish timestamp in header.stamp and a sequence number in
header.frame_id for drop detection on the subscriber side.

Usage:
    ros2 run orion_bench control_pub
    ros2 run orion_bench control_pub --ros-args \
        -p hz:=50 -p reliable:=true -p duration:=120
"""

import sys
import time
import math

import rclpy
from rclpy.node import Node
from geometry_msgs.msg import TwistStamped

from . import common


class ControlPublisher(Node):

    def __init__(self):
        super().__init__('control_pub')

        # Runtime parameters
        self.declare_parameter('hz', 50)
        self.declare_parameter('reliable', True)
        self.declare_parameter('duration', 0)  # 0 = run forever (Ctrl-C to stop)

        hz       = self.get_parameter('hz').value
        reliable = self.get_parameter('reliable').value
        self._duration = self.get_parameter('duration').value

        qos = common.get_qos(reliable)
        self._pub = self.create_publisher(
            TwistStamped, common.TOPIC_CONTROL, qos
        )
        self._timer = self.create_timer(1.0 / hz, self._tick)

        self._seq = 0
        self._start_mono = time.monotonic()

        self.get_logger().info(
            f"Publishing control msgs: {hz} Hz, "
            f"QoS={'RELIABLE' if reliable else 'BEST_EFFORT'}, "
            f"duration={'∞' if self._duration <= 0 else f'{self._duration}s'}"
        )

    def _tick(self):
        # Check duration limit
        if self._duration > 0:
            elapsed = time.monotonic() - self._start_mono
            if elapsed >= self._duration:
                self.get_logger().info(
                    f"Duration reached ({self._duration}s). "
                    f"Published {self._seq} messages."
                )
                raise SystemExit(0)

        msg = TwistStamped()

        # Timestamp for latency measurement. The ROS clock must match wall clock
        # when use_sim_time is false, which is our case)
        msg.header.stamp = self.get_clock().now().to_msg()

        # Sequence number encoded in frame_id for drop detection
        msg.header.frame_id = str(self._seq)

        # Simulate realistic control values (gentle sinusoidal motion)
        t = time.monotonic() - self._start_mono
        msg.twist.linear.x = 1.0 * math.sin(0.5 * t)
        msg.twist.linear.y = 0.0
        msg.twist.linear.z = 0.5
        msg.twist.angular.x = 0.0
        msg.twist.angular.y = 0.0
        msg.twist.angular.z = 0.3 * math.cos(0.5 * t)

        self._pub.publish(msg)
        self._seq += 1

    @property
    def messages_sent(self) -> int:
        return self._seq


def main(args=None):
    rclpy.init(args=args)
    node = ControlPublisher()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        node.get_logger().info(f"Total published: {node.messages_sent}")
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
