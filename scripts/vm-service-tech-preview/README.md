# Virtual Machine Service Tech Preview

## Overview

This document describes required procedures, additional configuration guides, and runbooks for the VM Service Tech Preview for IBM Sovereign Core.

## Procedures


### Prerequisites

1. The existing IBM documentation must have been followed to create a shared VM cluster.

### Installation

Once a shared VM cluster has been created, two additional scripts must be run — one against the shared VM cluster to complete the OAuth configuration, and one against the hub cluster to apply the IAM token refresh workaround.

**On the shared VM cluster:**

1. Login to the shared VM cluster

2. Run `configure-vm-oauth.sh`

3. Verify the OAuth configuration is configured in the cluster

**On the hub cluster:**

4. Login to the hub cluster

5. Run `apply-operator-restart-cronjob.sh`

**Resume IBM documentation:**

6. Resume the steps outlined in the IBM documentation to make the VM service tech preview public.


## Scripts

- [`configure-vm-oauth.sh`](./configure-vm-oauth.sh) — configures the OAuth identity provider on the shared VM cluster. Required on bare metal where the ACM-managed Jobs cannot run due to the internal image registry being unavailable.
- [`apply-operator-restart-cronjob.sh`](./apply-operator-restart-cronjob.sh) — applies a CronJob that periodically restarts the VM service broker operator to refresh its IAM token. Required until the automatic token re-authentication fix ships.

## Guides

- [Adding Guest OS Images](./adding-guest-os-images.md) — how to add additional
  guest OS images via DataImportCron resources on the shared VM cluster.
- [Cluster Resource Quotas](./quotas/cluster-resource-quotas.md) — sample ClusterResourceQuota
  configurations for managing resource limits across VM service namespaces.

## Runbooks

- [VM Service Operations Runbook](./vm-service-runbook.md) — full operational
  reference covering operations, monitoring, troubleshooting, maintenance, and security.