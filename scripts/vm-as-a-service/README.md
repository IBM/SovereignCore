# Virtual Machine as a Service

## Overview

This document describes required procedures, additional configuration guides, and runbooks for the VM as a Service (VMaaS) for IBM Sovereign Core.

## Procedures

### Prerequisites

1. The existing IBM documentation must have been followed to create a shared VM cluster.

> [!WARNING]
> A shared VM cluster on which the VMaaS Technology Preview has been installed cannot be used with the General Availability (GA) release of VMaaS. Before using the GA release, you must delete the Technology Preview cluster and create a new shared VM cluster.

### Installation

Once a shared VM cluster has been created, one additional script must be run against the hub cluster to allow the VM Dashboard to reach the shared VM cluster API server. Without it, VNC and Serial console connections fail.

**On the hub cluster:**

1. Login to the hub cluster
2. Run `allow-vm-cluster-console-access.sh`. See [Allowing VM Console Access to the VM Cluster](./allowing-vm-cluster-console-access.md) for details.
3. If the console still fails after step 2, see [Troubleshooting](./allowing-vm-cluster-console-access.md#troubleshooting) in the same guide.

## Scripts

- [`mirror-containerdisk-images.sh`](./mirror-containerdisk-images.sh) — mirror guest OS containerdisk images to the enterprise Quay registry for VM as a Service.
- [`allow-vm-cluster-console-access.sh`](./allow-vm-cluster-console-access.sh) — allow the VM Dashboard to reach the shared VM cluster API server for VNC and Serial consoles, by registering its IP in the `sovereign-ui` EgressFirewall on the hub cluster (or revert it).

## Guides

- [Uploading Guest OS Images](./uploading-guest-os-images.md) — how to upload guest OS images
- [Creating Linux Container Disk Images](./creating-linux-containerdisk-images.md) — how to build your own Linux containerdisk guest OS images
- [Allowing VM Console Access to the VM Cluster](./allowing-vm-cluster-console-access.md) — how to allow the VM Dashboard to reach the shared VM cluster API server, and how to revert it
- [Configuring the MetalLB Advertisement Mode](./configuring-metallb-advertisement-mode.md) — how to configure L2 or BGP advertisement mode before VM cluster initialization
- [Configuring Platform Storage Fallback](./configuring-platform-storage-fallback.md) — how to configure platform storage fallback when tenant storage is not configured