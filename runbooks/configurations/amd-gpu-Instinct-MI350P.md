# AMD Instinct MI350P GPU PCIe card on IBM Sovereign Core

## Overview

The IBM Sovereign Core team collaborated with AMD to test the AMD Instinct MI350P PCIe GPU card for AI inferencing within the secure environment of IBM Sovereign Core. The validation covered two scenarios:

1. **Sovereign Core AI inference stack** — verifying that the Sovereign Core AI inference stack operates correctly with an MI350P GPU.
2. **End-to-end AMD Blueprint integration** — verifying that the AMD blueprint [Financial Stock Intelligence](https://enterprise-ai.docs.amd.com/en/latest/solution-blueprints/catalog.html#financial-stock-intelligence) integrates correctly with the Sovereign Core AI inference stack on MI350P.

The AMD Instinct MI350P PCIe card is designed for enterprise AI workloads in existing air-cooled servers. For more information see the [AMD Instinct MI350P announcement](https://www.amd.com/en/blogs/2026/amd-instinct-mi350p-pcie-gpus-run-enterprise-ai-on-your.html).

---

## Validated solution blueprints

The following AMD enterprise AI blueprint was tested with Sovereign Core:

* [Financial Stock Intelligence](https://enterprise-ai.docs.amd.com/en/latest/solution-blueprints/catalog.html#financial-stock-intelligence)

---

## Configuration and considerations

*Due to the use of a beta driver and manual component upgrades to achieve version compatibility, this configuration should be considered a technical preview.*

### Component versions used in validation

| Component | Version | Maturity |
|---|---|---|
| AMD Kubernetes GPU Operator | v1.5.1-beta.0 | **Beta** |
| AMD GPU Driver (CoreOS 9.6) | 31.30 | **Preview** |
| ROCm | 7.13 | **Preview** |
| AMD-provided vLLM | ROCm 7.13 build | **Preview** |
| KMM (Kernel Module Management) | 2.4.1 | GA |
| OpenShift | 4.20 | GA |

---

## Step 1 — Mirror required images to Sovereign Quay (Hub Cluster)

All images must be mirrored into your Sovereign Quay Enterprise registry **before any cluster-side step**. Perform this step from the Landing Zone host.

### 1-1. Retrieve Quay credentials

```sh
QUAY=registry-quay-quay-enterprise.apps.mgmt.<your-domain>
QUAY_USER=$(oc get secret quay-credentials -n redhat-lz-admin -o jsonpath='{.data.username}' | base64 -d)
QUAY_PASS=$(oc get secret quay-credentials -n redhat-lz-admin -o jsonpath='{.data.password}' | base64 -d)
```

### 1-2. Mirror images using oc mirror (preferred)

Create `imageset.yaml`:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
    # Kernel Module Management (KMM)
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
      packages:
        - name: kernel-module-management
          defaultChannel: stable
          channels:
            - name: stable
              minVersion: 2.4.1
              maxVersion: 2.4.1

  additionalImages:
    # UBI base images
    - name: registry.redhat.io/ubi9/ubi:latest
    - name: registry.redhat.io/ubi9/ubi-minimal:latest

    # AMD GPU Operator (beta)
    - name: mirror.gcr.io/rocm/gpu-operator:v1.5.1-beta.0
    - name: mirror.gcr.io/rocm/gpu-operator-utils:v1.5.1-beta.0
    - name: mirror.gcr.io/rocm/device-metrics-exporter:v1.5.1-beta.0
    - name: mirror.gcr.io/rocm/amdgpu-driver:coreos-9.6-31.30
    - name: mirror.gcr.io/rocm/k8s-device-plugin:rhubi-latest

    # busybox (init container)
    - name: mirror.gcr.io/library/busybox:1.36

  blockedImages:
    - name: registry.redhat.io/kmm/kernel-module-management-must-gather-rhel8
    - name: registry.redhat.io/kmm/kernel-module-management-hub-operator-rhel8
    - name: registry.redhat.io/kmm/kernel-module-management-hub-operator-bundle
    - name: registry.redhat.io/kmm/kernel-module-management-operator-rhel8
    - name: registry.redhat.io/kmm/kernel-module-management-signing-rhel8
```

Run the mirror:

```sh
oc mirror --config=imageset.yaml \
  docker://${QUAY}/redhat \
  --v2
```

### 1-3. Fallback — mirror with skopeo (if oc mirror fails)

```sh
skopeo login ${QUAY} -u ${QUAY_USER} -p ${QUAY_PASS}

for IMG in \
  docker.io/rocm/gpu-operator:v1.5.1-beta.0 \
  docker.io/rocm/gpu-operator-utils:v1.5.1-beta.0 \
  docker.io/rocm/device-metrics-exporter:v1.5.1-beta.0 \
  docker.io/rocm/amdgpu-driver:coreos-9.6-31.30
do
  REPO=$(echo ${IMG} | sed 's|docker.io/||' | cut -d: -f1)
  TAG=$(echo ${IMG} | cut -d: -f2)
  skopeo copy docker://${IMG} docker://${QUAY}/${REPO}:${TAG}
done
```

---

## Step 2 — Label the target Managed Cluster (Hub Cluster)

Sovereign Core uses ACM policies to deploy the AMD GPU stack. Label the Managed Cluster that has the MI350P GPU installed:

```sh
oc label managedcluster <cluster-name> \
  sovcloud.open-cluster-management.io/amd-gpu=true
```

Apply the ACM placement and binding objects:

```yaml
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: openshift-ai-configuration-amd
  namespace: openshift-acm-policies
spec:
  clusterSelector:
    matchExpressions:
      - key: sovcloud.open-cluster-management.io/amd-gpu
        operator: In
        values:
          - "true"
```

```sh
oc apply -f placement-rule.yaml
```

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: openshift-ai-configuration-amd
  namespace: openshift-acm-policies
placementRef:
  apiGroup: apps.open-cluster-management.io
  kind: PlacementRule
  name: openshift-ai-configuration-amd
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: model-catalogsources
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: model-prerequisites
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: model-operators-crd-ready
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: model-configuration
```

```sh
oc apply -f placement-binding.yaml
```

---

## Step 3 — Configure image mirroring on the Managed Cluster

Log in to the **Managed Cluster** and apply the `ImageDigestMirrorSet` (IDMS) and `ImageTagMirrorSet` (ITMS) resources so that image pulls are redirected to your Sovereign Quay.

### 3-1. Apply IDMS

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: amd-preview-idms
spec:
  imageDigestMirrors:
    - mirrors:
        - registry-quay-quay-enterprise.apps.mgmt.<your-domain>/kmm
      source: registry.redhat.io/kmm
    - mirrors:
        - registry-quay-quay-enterprise.apps.mgmt.<your-domain>/rocm
      source: docker.io/rocm
```

### 3-2. Apply ITMS

```yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: amd-preview-itms
spec:
  imageTagMirrors:
    - mirrors:
        - registry-quay-quay-enterprise.apps.mgmt.<your-domain>/rocm
      source: docker.io/rocm
    - mirrors:
        - registry-quay-quay-enterprise.apps.mgmt.<your-domain>/busybox
      source: docker.io/library/busybox
    - mirrors:
        - registry-quay-quay-enterprise.apps.mgmt.<your-domain>/ubi9
      source: registry.redhat.io/ubi9
```

Apply both resources:

```sh
oc apply -f idms-add.yaml
oc apply -f itms-add.yaml
```

---

## Step 4 — Install Kernel Module Management (KMM) Operator

The AMD GPU Operator uses KMM to build and load the GPU kernel module. Install KMM **before** the AMD GPU Operator.

```sh
# Create namespace
oc create namespace openshift-kmm

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
EOF

# Create Subscription
# Note: set 'source' to the CatalogSource name generated by oc mirror
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kernel-module-management
  source: redhat-operator-index
  sourceNamespace: openshift-marketplace
EOF
```

Verify installation:

```sh
oc get csv -n openshift-kmm | grep kernel-module
# Expected: Succeeded
```

---

## Step 5 — Install AMD Kubernetes GPU Operator via Helm

### 5-1. Create the target namespace and Quay push secret

```sh
oc create namespace openshift-amd-gpu

oc create secret docker-registry quay-push-secret \
  -n openshift-amd-gpu \
  --docker-server="${QUAY}" \
  --docker-username="${QUAY_USER}" \
  --docker-password="${QUAY_PASS}"
```

### 5-2. Create the Helm values file

```sh
cat > /tmp/amd-gpu-values.yaml << EOF
kmm:
  enabled: false
  watch: true

node-feature-discovery:
  enabled: false

remediation:
  enabled: false
  installCRDs: false

controllerManager:
  manager:
    image:
      repository: ${QUAY}/rocm/gpu-operator
      tag: v1.5.1-beta.0
    imagePullPolicy: IfNotPresent

deviceConfig:
  spec:
    driver:
      enable: true
      useSourceImage: true
      version: "31.30"
      image: "${QUAY}/rocm/amdgpu-driver"
      imageRegistrySecret:
        name: quay-push-secret
    commonConfig:
      initContainerImage: ${QUAY}/library/busybox:1.36
      utilsContainer:
        image: ${QUAY}/rocm/gpu-operator-utils:v1.5.1-beta.0
        imagePullPolicy: IfNotPresent
    devicePlugin:
      devicePluginImage: ${QUAY}/rocm/k8s-device-plugin:rhubi-latest
      devicePluginImagePullPolicy: IfNotPresent
      nodeLabellerImage: ${QUAY}/rocm/k8s-device-plugin:labeller-latest
      nodeLabellerImagePullPolicy: IfNotPresent
    metricsExporter:
      enable: true
      image: ${QUAY}/rocm/device-metrics-exporter:v1.5.1-beta.0
      imagePullPolicy: IfNotPresent
    testRunner:
      enable: false
    configManager:
      enable: false
EOF
```

### 5-3. Install the Helm chart

```sh
helm install amd-gpu-operator \
  https://github.com/ROCm/gpu-operator/releases/download/v1.5.1-beta.0/gpu-operator-charts-v1.5.1-beta.0.tgz \
  -n openshift-amd-gpu \
  -f /tmp/amd-gpu-values.yaml \
  --timeout 10m
```

### 5-4. Verify GPU Operator pods

```sh
oc get pods -n openshift-amd-gpu
# Expected: All pods Running. No ImagePullBackOff.
```

---

## Step 6 — Verify MI350P GPU resource availability

Once the AMD GPU Operator and driver DaemonSet are running, verify that the MI350P appears as an allocatable resource on the GPU node:

```sh
oc get node <gpu-node> \
  -o jsonpath='{.status.allocatable.amd\.com/gpu}'
# Expected output: 1
```

If the output is `0` or absent, check the driver DaemonSet logs:

```sh
oc logs -n openshift-amd-gpu \
  -l app=amd-gpu-driver --tail=50
```

---

## Step 7 — Deploy a model via Sovereign Core AI Inference Service

### 7-1. Mirror the model image and vLLM runtime to Sovereign Quay (Hub Cluster)

**Model image (llama-3.3-70b-instruct):**

Mirror the Red Hat AI modelcar image directly with skopeo:

```sh
skopeo copy \
  docker://registry.redhat.io/rhelai1/modelcar-llama-3-3-70b-instruct:1.5 \
  docker://${QUAY}/aiiaas-models/llama-3-3-70b-instruct:1.5
```

**vLLM ROCm runtime image:**

The RHOAI-bundled vLLM does not include MI350P support. Build a custom image from the
following Dockerfile and push it to Sovereign Quay:

```dockerfile
FROM mirror.gcr.io/rocm/vllm:rocm7.13.0_gfx950-dcgpu_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1

USER root

RUN set -eux; \
    chgrp -R 0 /opt/python /app; \
    chmod -R g=u /opt/python /app; \
    chmod -R a+rX /opt/python /app; \
    chmod a+rx /root /root/.local /root/.local/share /root/.local/share/uv /root/.local/share/uv/python; \
    chmod -R a+rX /root/.local/share/uv/python/cpython-3.13-linux-x86_64-gnu; \
    chmod a+rx /opt/python/bin/vllm; \
    namei -l /opt/python/bin/python

USER 1001
```

Build and push:

```sh
podman build -t ${QUAY}/rocm/vllm-rocm:rocm7.13-mi350p .
podman push ${QUAY}/rocm/vllm-rocm:rocm7.13-mi350p
```

> **Note:** The base image `mirror.gcr.io/rocm/vllm:rocm7.13.0_gfx950-dcgpu_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1`
> must be accessible from the build host. If building in an air-gapped environment,
> mirror the base image to Sovereign Quay first and update the `FROM` line accordingly.

---

### 7-2. Create a ModelDeployment CR (Hub Cluster)

Log in to the **Hub Cluster** and create a `ModelDeployment` CR that targets the MI350P GPU. Key fields:

```yaml
apiVersion: sovereign.cloud.ibm.com/v1
kind: ModelDeployment
metadata:
  finalizers:
  - modeldeployment.sovereign.cloud.ibm.com/finalizer
  name: <uuid>
  namespace: aiiaas
spec:
  displayName: llama-3.3-70b-instruct
  enabled: true
  llmInferenceServiceSpec:
    model:
      name: meta-llama/llama-3.3-70b-instruct
      uri: oci://${QUAY}/aiiaas-models/llama-3-3-70b-instruct:1.5
    replicas: 1
    router:
      gateway: {}
      route: {}
      scheduler: {}
    template:
      containers:
        - env:
            - name: VLLM_ADDITIONAL_ARGS
              value: --enable-prompt-tokens-details
          name: main                                           # Required: container name expected by KServe
          image: ${QUAY}/rocm/vllm-rocm:rocm7.13-mi350p       # AMD-provided vLLM build (ROCm 7.13)
          resources:
            limits:
              cpu: "4"
              memory: 16Gi
              amd.com/gpu: "1"
            requests:
              cpu: "2"
              memory: 8Gi
```

Apply and watch for readiness:

```sh
oc apply -f modeldeployment-llama-mi350p.yaml

oc get modeldeployment <uuid> \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' --watch
# Expected: True (allow up to 10 minutes for the model to load)
```

Confirm the pod is running on the GPU node:

```sh
oc get pod -n <inference-ns> -l app=<uuid> -o wide
oc describe pod <vllm-pod-name> -n <inference-ns> | grep -A5 "Limits:"
# Expected: amd.com/gpu: 1 in Limits
```

### Test direct inference (without a blueprint)

```sh
curl -s -X POST https://<model-gateway-host>/v1/chat/completions \
  -H "Authorization: Bearer <service-instance-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/llama-3.3-70b-instruct",
    "messages": [{"role": "user", "content": "Hello — confirm you are running."}],
    "stream": false
  }' | jq '.choices[0].message.content'
# Expected: non-empty string response, HTTP 200
```

---

## Step 8 — Deploy and run the Financial Stock Intelligence Blueprint

The Financial Stock Intelligence Blueprint connects to Sovereign Core's AI Inference Service via the `llm.existingService` Helm parameter. The blueprint acts as an external model consumer; the model itself runs on MI350P inside the Sovereign Core AI stack.

### 8-1. Apply Blueprint network policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: blueprint-egress-model-gateway-only
  namespace: <blueprint-ns>
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: model-gateway
      ports:
        - port: 443
```

### 8-2. Deploy the Blueprint via Helm

```sh
helm install fsi-blueprint <quay-chart-reference> \
  --namespace <blueprint-ns> \
  --create-namespace \
  --set llm.existingService="https://<model-gateway-host>/v1" \
  --set llm.model="meta-llama/llama-3.3-70b-instruct" \
  --set llm.apiKey="<service-instance-api-key>" \
  --set storage.ephemeral.storageClassName="ceph-rbd-platform" \
  --set llm.storage.ephemeral.storageClassName="ceph-rbd-platform"
```

### 8-3. Inject the Model Gateway CA certificate

The Blueprint's Python HTTP client validates TLS certificates. The Model Gateway uses a cluster-internal CA that is not in the default system trust store. Inject the CA before running any stock analysis requests.

```sh
# Extract the Model Gateway CA certificate
oc get secret model-gateway-tls -n aiiaas \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > model-gateway-ca.crt

# Create a ConfigMap from the certificate
oc create configmap llm-ca-bundle \
  --from-file=ca-bundle.crt=model-gateway-ca.crt \
  -n <blueprint-ns>

# Patch the Blueprint deployment to mount the certificate
oc patch deployment <blueprint-deployment> -n <blueprint-ns> --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "mountPath": "/etc/ssl/ca-bundle",
      "name": "ca-bundle",
      "readOnly": true
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "ca-bundle",
      "configMap": {
        "name": "llm-ca-bundle"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "REQUESTS_CA_BUNDLE",
      "value": "/etc/ssl/ca-bundle/ca-bundle.crt"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "SSL_CERT_FILE",
      "value": "/etc/ssl/ca-bundle/ca-bundle.crt"
    }
  }
]'

oc rollout status deploy/<blueprint-deployment> -n <blueprint-ns>
```

### 8-4. Verify Blueprint connectivity to Model Gateway

```sh
oc exec -n <blueprint-ns> <blueprint-pod> -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer <api-key>" \
  https://<model-gateway-host>/v1/models
# Expected: 200
```

### 8-5. Run stock analysis (Run 1 and Run 2)

Submit a stock ticker query through the Blueprint UI or its API endpoint.

**Expected**: Blueprint returns a non-empty stock analysis response. No errors in Blueprint pod logs.

Repeat the request once more on the same hardware and configuration without restarting any pods to confirm reproducibility (NFR-2 requires ≥ 2/2 successful runs).

---

## References

- [IBM Sovereign Core Ecosystem page](https://www.ibm.com/products/sovereign-core/ecosystem)
- IBM Sovereign Core [AI inference service](https://www.ibm.com/docs/en/sovereign-core/1.1.0?topic=service-ai-inference)
- [AMD Instinct MI350P PCIe announcement](https://www.amd.com/en/blogs/2026/amd-instinct-mi350p-pcie-gpus-run-enterprise-ai-on-your.html)
- [AMD enterprise AI solution blueprints catalog](https://enterprise-ai.docs.amd.com/en/latest/solution-blueprints/catalog.html)
- [AMD enterprise AI blueprints — ROCm blog](https://rocm.blogs.amd.com/artificial-intelligence/enterprise-ai-blueprints/README.html)
- [AMD GPU Operator Helm chart release (v1.5.1-beta.0)](https://github.com/ROCm/gpu-operator/releases/tag/v1.5.1-beta.0)
- [Financial Stock Intelligence Blueprint values.yaml](https://github.com/amd-enterprise-ai/solution-blueprints/blob/main/solution-blueprints/fsi/values.yaml)
