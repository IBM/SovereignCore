# PostgreSQL Image Catalog Setup

This script generates OpenShift Policy YAML files for PostgreSQL image catalogs and optionally applies them to the cluster.

## Overview

The script:
1. Reads a configuration file specifying PostgreSQL versions and image paths
2. Validates the configuration
3. Verifies that all images exist in the registry using `podman manifest inspect`
4. Generates a Policy YAML file from a template
5. Optionally applies the generated YAML to the OpenShift cluster

## Prerequisites

### Required Tools

- **yq**: YAML processor
  - Installation: https://github.com/mikefarah/yq
  - macOS: `brew install yq`
  - Linux: Download from releases page

- **podman**: Container tool for image verification
  - macOS: `brew install podman`
  - RHEL/Fedora: `sudo dnf install podman`

- **oc**: OpenShift CLI (required only with `--apply` flag)
  - Download: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/

### Authentication

Before running the script, authenticate to your container registry:

```bash
podman login quay.io
# or
podman login your-registry.example.com
```

## Configuration File

Create a YAML configuration file specifying your PostgreSQL images. See `config.example.yaml` for a template.

### Configuration Format

```yaml
# Catalog version - used in Policy names and generated YAML filename
catalog_version: "1.0.0"

# PostgreSQL images - list of versions and their image paths
postgres_images:
  - major: 16
    image: "quay.io/myorg/postgres:16-v1.0.0"
  
  - major: 17
    image: "quay.io/myorg/postgres:17-v1.0.0"
  
  - major: 18
    image: "quay.io/myorg/postgres:18-v1.0.0"
```

### Configuration Fields

- **catalog_version** (required): Semantic version string (e.g., "1.0.0")
  - Used in Policy metadata names
  - Used in generated YAML filename

- **postgres_images** (required): Array of PostgreSQL image definitions
  - **major** (required): PostgreSQL major version number (integer)
  - **image** (required): Full OCI image reference including registry, repository, and tag

### Flexible Version Support

You can specify any number of PostgreSQL versions. The script supports:
- Standard versions (16, 17, 18)
- Future versions (19, 20, etc.)
- Custom version numbers

Example with additional versions:

```yaml
catalog_version: "2.0.0"

postgres_images:
  - major: 15
    image: "quay.io/myorg/postgres:15-v2.0.0"
  
  - major: 16
    image: "quay.io/myorg/postgres:16-v2.0.0"
  
  - major: 17
    image: "quay.io/myorg/postgres:17-v2.0.0"
  
  - major: 18
    image: "quay.io/myorg/postgres:18-v2.0.0"
  
  - major: 19
    image: "quay.io/myorg/postgres:19-v2.0.0"
```

## Usage

### Basic Usage

```bash
# Generate YAML only
./setup-postgres-catalog.sh -c config.yaml

# Generate and apply to cluster
./setup-postgres-catalog.sh -c config.yaml --apply

# Validate configuration and check images (dry run)
./setup-postgres-catalog.sh -c config.yaml --dry-run

# Specify custom output directory
./setup-postgres-catalog.sh -c config.yaml -o /path/to/output
```

### Command-Line Options

```
Required:
  -c, --config FILE         Path to configuration YAML file

Options:
  -a, --apply               Apply the generated YAML to the cluster using 'oc apply'
  -d, --dry-run             Validate configuration and check images without generating YAML
  -o, --output-dir DIR      Output directory for generated YAML (default: ./generated)
  -h, --help                Show help message
```

## Workflow

### 1. Prepare Configuration

Create a configuration file based on `config.example.yaml`:

```bash
cp config.example.yaml my-config.yaml
# Edit my-config.yaml with your image paths
```

### 2. Authenticate to Registry

```bash
podman login quay.io
# Enter your credentials
```

### 3. Validate Configuration (Optional)

Run a dry run to validate your configuration and verify image accessibility:

```bash
./setup-postgres-catalog.sh -c my-config.yaml --dry-run
```

### 4. Generate YAML

Generate the Policy YAML file:

```bash
./setup-postgres-catalog.sh -c my-config.yaml
```

This creates: `generated/install-postgres-image-catalog-<version>.yaml`

### 5. Review Generated YAML

Review the generated file before applying:

```bash
cat generated/install-postgres-image-catalog-1.0.0.yaml
```

### 6. Apply to Cluster

Apply the Policy to your OpenShift cluster:

```bash
# Option 1: Use the script
./setup-postgres-catalog.sh -c my-config.yaml --apply

# Option 2: Apply manually
oc apply -f generated/install-postgres-image-catalog-1.0.0.yaml
```

## Output

### Generated Files

The script generates a Policy YAML file in the output directory:

```
generated/
└── install-postgres-image-catalog-<version>.yaml
```

### Generated Policy Structure

The generated YAML includes:
- **Policy**: Defines the PostgreSQL image catalog configuration
- **PlacementBinding**: Binds the Policy to target clusters

Example structure:

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-postgres-image-catalog-1.0.0
  namespace: postgres-service-broker
spec:
  policy-templates:
  - objectDefinition:
      apiVersion: policy.open-cluster-management.io/v1
      kind: ConfigurationPolicy
      metadata:
        name: create-postgres-image-catalog-1.0.0
      spec:
        object-templates:
        - complianceType: musthave
          objectDefinition:
            apiVersion: postgresql.k8s.enterprisedb.io/v1
            kind: ClusterImageCatalog
            metadata:
              name: postgresql-image-catalog-1.0.0
            spec:
              images:
              - image: quay.io/myorg/postgres:16-v1.0.0
                major: 16
              - image: quay.io/myorg/postgres:17-v1.0.0
                major: 17
              - image: quay.io/myorg/postgres:18-v1.0.0
                major: 18
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: binding-install-postgres-image-catalog-1.0.0
  namespace: postgres-service-broker
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: placement-install-postgres-operator-olm
subjects:
- apiGroup: policy.open-cluster-management.io
  kind: Policy
  name: install-postgres-image-catalog-1.0.0
```

## Verification

After applying the Policy, verify the deployment:

```bash
# Check Policy status
oc get policy -n postgres-service-broker

# Check ClusterImageCatalog
oc get clusterimagecatalog

# View detailed status
oc describe clusterimagecatalog postgresql-image-catalog-1.0.0
```

## Troubleshooting

### Image Verification Fails

**Error**: `Image not found or not accessible`

**Solutions**:
1. Verify you're authenticated to the registry:
   ```bash
   podman login quay.io
   ```

2. Check the image path is correct:
   ```bash
   podman manifest inspect quay.io/myorg/postgres:16-v1.0.0
   ```

3. Verify the image exists in the registry (check via web UI or API)

### Missing Prerequisites

**Error**: `'yq' command not found`

**Solution**: Install yq:
```bash
# macOS
brew install yq

# Linux
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq
```

### Configuration Validation Errors

**Error**: `Missing required field: catalog_version`

**Solution**: Ensure your configuration file includes all required fields:
```yaml
catalog_version: "1.0.0"
postgres_images:
  - major: 16
    image: "quay.io/myorg/postgres:16-v1.0.0"
```

### Apply Fails

**Error**: `Failed to apply YAML to cluster`

**Solutions**:
1. Verify you're logged into the OpenShift cluster:
   ```bash
   oc whoami
   ```

2. Check you have permissions to create Policies:
   ```bash
   oc auth can-i create policy -n postgres-service-broker
   ```

3. Verify the namespace exists:
   ```bash
   oc get namespace postgres-service-broker
   ```

## Examples

### Example 1: Basic Setup

```bash
# Create configuration
cat > config.yaml <<EOF
catalog_version: "1.0.0"
postgres_images:
  - major: 16
    image: "quay.io/myorg/postgres:16-v1.0.0"
  - major: 17
    image: "quay.io/myorg/postgres:17-v1.0.0"
EOF

# Authenticate
podman login quay.io

# Generate and apply
./setup-postgres-catalog.sh -c config.yaml --apply
```

### Example 2: Multiple Versions

```bash
# Create configuration with 5 versions
cat > config.yaml <<EOF
catalog_version: "2.0.0"
postgres_images:
  - major: 14
    image: "quay.io/myorg/postgres:14-v2.0.0"
  - major: 15
    image: "quay.io/myorg/postgres:15-v2.0.0"
  - major: 16
    image: "quay.io/myorg/postgres:16-v2.0.0"
  - major: 17
    image: "quay.io/myorg/postgres:17-v2.0.0"
  - major: 18
    image: "quay.io/myorg/postgres:18-v2.0.0"
EOF

# Validate first
./setup-postgres-catalog.sh -c config.yaml --dry-run

# Generate
./setup-postgres-catalog.sh -c config.yaml
```

### Example 3: Custom Output Directory

```bash
# Generate to specific directory
./setup-postgres-catalog.sh -c config.yaml -o /tmp/postgres-policies

# Apply from custom location
oc apply -f /tmp/postgres-policies/install-postgres-image-catalog-1.0.0.yaml
```

## Directory Structure

```
postgres-catalog-setup/
├── setup-postgres-catalog.sh          # Main script
├── config.example.yaml                # Example configuration
├── README.md                          # This file
├── templates/
│   └── install-postgres-image-catalog-template.yaml
└── generated/                         # Generated YAML files (created by script)
    └── install-postgres-image-catalog-<version>.yaml
```

## Integration with Landing Zone

This script is designed to run in a Landing Zone environment:

1. **Prerequisites**: Ensure all required tools are installed in the Landing Zone
2. **Authentication**: Set up registry authentication before running
3. **Configuration**: Store configuration files in version control
4. **Automation**: Can be integrated into CI/CD pipelines

### CI/CD Integration Example

```bash
#!/bin/bash
# CI/CD pipeline script

# Authenticate to registry
echo "$QUAY_PASSWORD" | podman login quay.io -u "$QUAY_USERNAME" --password-stdin

# Generate and apply
cd scripts/postgres-catalog-setup
./setup-postgres-catalog.sh -c production-config.yaml --apply

# Verify
oc get policy -n postgres-service-broker
```

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review the generated YAML file for correctness
3. Verify all prerequisites are installed and configured
4. Check OpenShift cluster connectivity and permissions