# Virtual Machine Service Tech Preview

## Overview

This document describes procedures for configuring the VM Service Tech Preview for IBM Sovereign Core.

## Prerequisites

1. Mirror example Fedora image from `quay.io/containerdisks/fedora:43-1.6` to control plane's registry at `$QUAY_URL/sovcloud/cp/sovereign-cloud-platform/automation-saas-platform-dev/containerdisks/fedora:43-1.6`.  See the Helm chart's values file for the registry URL pattern.

2. Sign into the control plane's Account UI as the platform tenant and create a shared cluster with the `vm.sovereign.cloud.ibm.com/virtualization-enabled=true` label.

3. Login to the control plane's OpenShift cluster via the `oc` CLI.

## Procedure

1. Run `configure-chart-overrides.sh https://console-openshift-console.apps.<domain>` with optional argument of shared cluster console URL to generate a values override file called `values-override.yaml` for the `vm-service-broker` Helm chart.

2. Run `helm install vm-service-broker charts/vm-service-broker -f values-override.yaml` to deploy the Helm chart to the control plane cluster.

   If shared cluster console URL is not specified, this script will attempt to lookup details for the first managed cluster with the `vm.sovereign.cloud.ibm.com/virtualization-enabled=true` label.

3. Run `configure-sso-client.sh` with optional argument of shared cluster console URL to create an IDP client to be used in the shared cluster's OAuth configuration and create some local manifests to be used to configure Oauth for the shared cluster.

   If shared cluster console URL is not specified, this script will attempt to lookup details for the first managed cluster with the `vm.sovereign.cloud.ibm.com/virtualization-enabled=true` label.

4. Login to the shared cluster via `oc` CLI.

5. Run `configure-vm-oauth.sh` to deploy generated client resources and add an identity provider to the shared cluster's OAuth configuration to allow tenant SSO login.

6. Ensure there is a default storage class set for the shared cluster. This will be used for the Fedora sample container disk image as well as be the default for all created Virtual Machines.

7. Login to the control plane's MSP UI and set the VM Service Tech Preview as visible in the catalog to enable tenants to provision the service.