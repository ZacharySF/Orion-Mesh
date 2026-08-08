from setuptools import find_packages, setup

package_name = 'orion_bench'

setup(
    name=package_name,
    version='0.1.0',
    packages=find_packages(),
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='ground',
    maintainer_email='ground@orion',
    description='ROS 2 control-message latency bench for Orion mesh experiments',
    license='MIT',
    entry_points={
        'console_scripts': [
            'control_pub = orion_bench.control_pub:main',
            'control_sub = orion_bench.control_sub:main',
        ],
    },
)
