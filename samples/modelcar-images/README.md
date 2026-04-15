# Modelcar Image Upload Scripts

This directory contains scripts to upload modelcar images for IBM Sovereign Core AI inference service.

## Overview

[Modelcar](https://kserve.github.io/website/docs/model-serving/storage/providers/oci) images are OCI-compliant container images that contain model files in a standardized format. These scripts help you:

1. Mirror pre-built modelcar images from Red Hat's catalog to your registry
2. Build custom modelcar images from Hugging Face models and push them to your registry

Modelcars are uploaded to the `aiiaas-models` repository in your Quay registry.

## Scripts

### 1. [mirror-modelcar-images.sh](./mirror-modelcar-images.sh)

Mirrors modelcar images from the Red Hat AI Services modelcar-catalog registry to your target Quay registry using `skopeo copy`.

**Source Registry:** https://quay.io/repository/redhat-ai-services/modelcar-catalog

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

This script mirrors images from source tags to target repository names with a specified tag:
- Source: `quay.io/redhat-ai-services/modelcar-catalog:granite-4.0-h-small`
- Target: `your-registry/aiiaas-models/granite-4.0-h-small:v1` (or custom tag)

The source tag becomes the target repository name, and you can specify a common target tag for all mirrored images.

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
# Mirror specific image with default target tag (v1)
./mirror-modelcar-images.sh -r registry-quay-quay-enterprise.apps.example.com \
  -i granite-4.0-h-small

# Mirror with custom target tag
./mirror-modelcar-images.sh -r registry-quay-quay-enterprise.apps.example.com \
  -i granite-4.0-h-small \
  -t v2

# Dry run (preview without executing)
./mirror-modelcar-images.sh -r registry-quay-quay-enterprise.apps.example.com \
  -i granite-4.0-h-small \
  -d
```

**Options:**
- `-r, --target-registry URL` - Target registry URL (required)
- `-t, --tag TAG` - Target tag for all mirrored images (default: v1)
- `-s, --source-registry URL` - Source registry (default: quay.io/redhat-ai-services/modelcar-catalog)
- `-i, --images TAGS` - Source image tags to mirror (comma-separated)
- `-d, --dry-run` - Preview operations without executing
- `-k, --insecure` - Skip TLS certificate verification (for self-signed certificates)
- `-h, --help` - Show help message

---

### 2. [build-modelcar-from-hf.sh](./build-modelcar-from-hf.sh)

Builds modelcar images from Hugging Face models and pushes them to your registry. This script automates the entire process: downloading the model, creating a container image, and pushing to your registry.

**Prerequisites:**
- Podman
- Hugging Face CLI (`hf`)

**Installation:**
```bash
# Install Hugging Face CLI
curl -LsSf https://hf.co/cli/install.sh | bash

# Install Podman
# macOS
brew install podman

# RHEL/Fedora
sudo dnf install podman
```

**Start VM (macOS):**

Please start the VM by running the following command (or use Podman Desktop):

```bash
podman machine init
podman machine start
```

**Usage:**

Before running the script, ensure you are logged in to the target registry (same as mirror-modelcar-images.sh):

```bash
# Login to target registry
podman login registry-quay-quay-enterprise.apps.example.com

# For registries with self-signed certificates
podman login --tls-verify=false registry-quay-quay-enterprise.apps.example.com
```

Then run the build script:

```bash
# Basic usage (uses default model: ibm-granite/granite-4.0-1b)
./build-modelcar-from-hf.sh -r registry-quay-quay-enterprise.apps.example.com

# Or specify a different model
./build-modelcar-from-hf.sh \
  ibm-granite/granite-4.0-micro \
  -r registry-quay-quay-enterprise.apps.example.com

# Custom tag
./build-modelcar-from-hf.sh \
  ibm-granite/granite-4.0-micro \
  -r registry-quay-quay-enterprise.apps.example.com \
  -t v2

# Skip download if model exists locally
./build-modelcar-from-hf.sh \
  ibm-granite/granite-4.0-micro \
  -r registry-quay-quay-enterprise.apps.example.com \
  -s

# With insecure flag for self-signed certificates
./build-modelcar-from-hf.sh \
  ibm-granite/granite-4.0-micro \
  -r registry-quay-quay-enterprise.apps.example.com \
  -k
```

**Options:**
- `-r, --target-registry URL` - Target registry URL (required)
- `-t, --tag TAG` - Image tag (default: v1)
- `-s, --skip-download` - Skip model download if files exist locally
- `-k, --insecure` - Skip TLS certificate verification (for self-signed certificates)
- `-h, --help` - Show help message

**Environment Variables:**
- `HF_TOKEN` - Hugging Face token (required for private models)

## References

- [Serving Models with OCI Images](https://kserve.github.io/website/docs/model-serving/storage/providers/oci)
- [Red Hat AI Services Modelcar Catalog](https://quay.io/repository/redhat-ai-services/modelcar-catalog)
