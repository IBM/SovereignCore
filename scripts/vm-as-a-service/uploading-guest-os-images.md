# Guest OS Image Upload Script

This directory contains a script to upload guest OS images for the IBM Sovereign Core VM as a Service.

## Overview

[Containerdisk](https://kubevirt.io/user-guide/storage/disks_and_volumes/#containerdisk) images are OCI-compliant container images that contain a VM disk image. The [mirror-containerdisk-images.sh](./mirror-containerdisk-images.sh) script mirrors pre-built containerdisk images from the public KubeVirt containerdisks registry to your registry.

Containerdisk images are uploaded to the `vm-containerdisks` organization in your Quay registry.

## mirror-containerdisk-images.sh

Mirrors containerdisk images from the `quay.io/containerdisks` registry to your target Quay registry using `skopeo copy`.

**Source Registry:** https://quay.io/organization/containerdisks

**Prerequisites:**
- Skopeo

**Installation:**
```bash
# macOS
brew install skopeo

# RHEL/Fedora
sudo dnf install skopeo
```

**How it works:**

This script mirrors images from source repositories to the same repository name and tag within the organization:
- Source: `quay.io/containerdisks/fedora:44`
- Target: `your-registry/vm-containerdisks/fedora:44`

Each image is specified as `name:tag`. The tag of the mirrored image is always the same as the tag of the source image.

Source images are usually multi-architecture. By default, only the `linux/amd64` image is mirrored, because the cluster supports amd64 only. Use `-a all` to mirror every platform, or `-a <arch>` for another architecture.

**Usage:**

Before running the script, ensure you are logged in to the target registry:

```bash
# Login to target registry
skopeo login registry-quay-quay-enterprise.apps.example.com

# For registries with self-signed certificates, use --tls-verify=false
skopeo login --tls-verify=false registry-quay-quay-enterprise.apps.example.com
```

Then run the mirror script:

```bash
# Mirror a specific image
./mirror-containerdisk-images.sh -r registry-quay-quay-enterprise.apps.example.com \
  -i fedora:44

# Mirror multiple images
./mirror-containerdisk-images.sh -r registry-quay-quay-enterprise.apps.example.com \
  -i fedora:44,ubuntu:22.04

# Dry run (preview without executing)
./mirror-containerdisk-images.sh -r registry-quay-quay-enterprise.apps.example.com \
  -i fedora:44 \
  -d
```

**Options:**
- `-r, --target-registry URL` - Target registry URL (required)
- `-i, --images IMAGES` - Source images to mirror as `name:tag` (comma-separated, required)
- `-s, --source-registry URL` - Source registry (default: quay.io/containerdisks)
- `-a, --arch ARCH` - Architecture to mirror, or `all` for every platform (default: amd64)
- `-d, --dry-run` - Preview operations without executing
- `-k, --insecure` - Skip TLS certificate verification (for self-signed certificates)
- `-h, --help` - Show help message
