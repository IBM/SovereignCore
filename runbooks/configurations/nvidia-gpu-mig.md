# Configuring Multi-Instance GPU (MIG) for NVIDIA GPUs

## Introduction

The Multi-Instance GPU (MIG) feature, available on supported NVIDIA GPUs, allows GPUs to be securely partitioned into instances.

> [!NOTE]
> Make sure the NVIDIA GPU hardware uses the Ampere architecture or a later architecture.

This document describes how a system owner configures this feature in the AI inference service.

## Prerequisites

- You must have the System owner role in the account with access to the credentials to log in to the management cluster where IBM Sovereign Core is installed.
- The platform account owner must create the shared cluster for the AI inference service with the GPU operator installed.
- Remove all foundation model pods from the cluster. You cannot partition GPUs while model deployments are active.

## About the strategy

NVIDIA MIG provides single (homogeneous) and mixed (heterogeneous) advertisement strategies.

You have the following options when you configure NVIDIA MIG:

### Single strategy

You can use the same profile on all of the GPU worker nodes in your cluster. All worker nodes are identified in the custom resource for the deployed model as a separate resource as a single generic GPU resource called nvidia.com/gpu. Kubernetes treats all slices as equivalent and does not distinguish between MIG sizes.
For example, the deployed model's custom resource contains the following section:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

### Mixed strategy

You can use different profiles on each worker node in your cluster. Each profile is identified in the custom resource for the deployed model as a separate resource, such as nvidia.com/mig-1g.5gb. Kubernetes can schedule workloads based on specific MIG sizes.

> [!CAUTION]
> The IBM Sovereign Core UI does not support resource notation for the mixed strategy. If you set the mixed strategy, you cannot deploy models from the UI and you must use the CLI instead.

For example, the deployed model's custom resource contains the following section:

```yaml
resources:
  limits:
    nvidia.com/mig-1g.5gb: 1
```

Review [MIG support in Red Hat OpenShift Container Platform](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/mig-ocp.html) in the NVIDIA documentation for more information about advertisement strategies and MIG profiles.

## Procedure

1. Set the NVIDIA MIG strategy. The strategy is managed by the nvidia-gpu-configuration policy on the management cluster.
     1. From the management cluster, check the existing MIG strategy by running the following command:

        ```sh
        oc get policy -n openshift-acm-policies nvidia-gpu-configuration -o yaml
        ```

     2. To change the strategy, update the strategy field of the gpu-cluster-policy object.
     In the following example, the path assumes that `gpu-cluster-policy` is defined at position 4 (0-based index) of the object-templates array. Verify the correct index for your environment before running the command.
     Replace new-strategy with either single or mixed.

        ```sh
        oc patch policy nvidia-gpu-configuration \
            -n openshift-acm-policies \
            --type=json \
            -p='[
            {
                "op": "replace",
                "path": "/spec/policy-templates/0/objectDefinition/spec/object-templates/3/objectDefinition/spec/mig/strategy",
                "value": "<new-strategy>"
            }
            ]'
        ```

2. Get the Kubernetes context of the AI inference service cluster. For details, see the [Kubernetes reference documentation](https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/).
    Identify the nodes with GPUs that can be allocated by running the following command:

    ```sh
    oc get nodes --context "<ai-inference-cluster-context>" \
        -o "custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"
    ```

    A list of node names and their allocatable GPU counts is displayed.

3. Get the GPU capacity of each node by running the following command:

    ```sh
    oc get nodes --context "<ai-inference-cluster-context>" \
    -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}'
    ```

    Select the node whose GPU you want to partition from the list.

4. Check whether a foundation model is deployed on the node by running the following command:

    ```sh
    oc get po --context "<ai-inference-cluster-context>" -n llms -o wide
    ```

    The pods running in the llms namespace are listed with their node assignments. If a model deployment is running on the target node, delete the model deployment. MIG cannot be configured while model deployments are active on a node.

5. Review the supported MIG profiles to choose the profile you want to configure. For details, see [Supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html).
    Run the following command to view the default profiles already configured in the service cluster:

    ```sh
    oc get cm --context "<ai-inference-cluster-context>" \
    -n nvidia-gpu-operator default-mig-parted-config \
    -o go-template='{{index .data "config.yaml"}}'
    ```

6. Set the MIG profile on the GPU node.
    Replace node-name with the target node name and profile-name with the selected profile.
    ```sh
    oc label node <node-name> nvidia.com/mig.config=<profile-name> --overwrite
    ```

7. Redeploy models if you removed them as part of this procedure.
