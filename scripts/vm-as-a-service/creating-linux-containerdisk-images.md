# Creating Container Disk Images

This guide describes how to build your own containerdisk (VM guest OS) images for the IBM Sovereign Core VM as a Service.

## Overview

[Containerdisk](https://kubevirt.io/user-guide/storage/disks_and_volumes/#containerdisk) images are OCI-compliant container images that contain a VM disk image. The public [kubevirt/containerdisks](https://github.com/kubevirt/containerdisks) project provides pre-built images, but an MSP may want to build and maintain their own images.

Once built, use the [`mirror-containerdisk-images.sh`](./mirror-containerdisk-images.sh) script to mirror the image from your local registry to the enterprise Quay registry.

## Building a container disk image

Follow the instructions in the [kubevirt/containerdisks](https://github.com/kubevirt/containerdisks) repository to build a containerdisk image:

1. Clone the repository.
2. Choose or create a disk image definition for your guest OS.
3. Build the image, producing an OCI container image that contains the VM disk.
4. Tag and push the image to your local registry.

> [!NOTE]
> We only support Linux guest OS images with **cloud-init** enabled. Other operating systems or images without cloud-init are not supported.

## Mirroring the image

After pushing your locally built image to your local registry, mirror it to the enterprise Quay registry:

```bash
./mirror-containerdisk-images.sh \
  -r registry-quay-quay-enterprise.apps.example.com \
  -s your-local-registry:5000 \
  -i my-guest-os:latest
```

See the [mirror-containerdisk-images.sh](./mirror-containerdisk-images.sh) script for all available options.
