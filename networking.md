## Networking Architecture

When configuring OCP networking for an OpenShift Virtualization deployment, we need to consider the following networks:

- management network (a.k.a node network).
- storage network (if using storage over IP).
- VM networks. These are typically VLANS, but could be also UDNs from OCP 4.18 onward.
- live migration network (optional). This is the network over which live migrations occur. If physically separate from other networks then live migrations do not interfere with normal operations. If not configured the management network will be used.
- migration network (optional). This is the network used by MTV to perform VM migrations. If physically separate from other networks then live migrations do not interfere with normal operations. If not configured the management network will be used.
- provisioning network. If using PXE boot as a way to boot and configure node a DHCP-enabled provisioning network is required.

Some networks can be configured at node creation time. When the network are static, such as usually management storage and provisioning are, it is recommended to configure them at node creation time.

Other networks will be configured as day2 configuration using NNCPs and NADs.

It is recommended to create a node network configuration design with all these considerations.

For the networks that are configured at node creation time:

1. this is out of scope for the first cluster of course.
2. for the other clusters and for an example of that configuration look at the [nmstate-config files](./clusters/hub/overlays/cluster-etl4/x240m5-11-nmstate-config.yaml)

For the networks that are configured at day2 look at the [nmstate-configuration overlay](./clusters/etl4/overlays/nmstate-configuration/) as an example.