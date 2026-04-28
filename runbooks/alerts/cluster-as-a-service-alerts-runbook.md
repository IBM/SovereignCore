# Cluster as a Service Alerts Runbook

## Overview
This runbook covers alerts related to Cluster as a Service (ACM Service Broker) availability and performance. The service provides automated OpenShift cluster provisioning using Red Hat Advanced Cluster Management (ACM).

---

## Basic Health Alerts

### ClusterAsAServiceControllerDown

#### Meaning
The ACM Service Broker Controller deployment has fewer available replicas than desired.

#### Impact
- Cluster provisioning and lifecycle management unavailable
- Existing cluster operations may be interrupted
- Critical service disruption

#### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment -n acm-service-broker acm-service-broker-controller
   ```
2. Check pod status:
   ```bash
   oc get pods -n acm-service-broker -l app=acm-service-broker-controller
   ```
3. Check pod logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=100
   ```
4. Check pod events:
   ```bash
   oc describe pod -n acm-service-broker -l app=acm-service-broker-controller
   ```

#### Mitigation
1. Check for resource constraints (CPU/memory)
2. Review recent deployments or configuration changes
3. Restart failed pods if necessary
4. Check for image pull errors
5. Verify RBAC permissions
6. Escalate to development team if application issue

---

### ClusterAsAServiceApiDown

#### Meaning
The ACM Service Broker API deployment has fewer available replicas than desired.

#### Impact
- Service broker API unavailable
- Cannot receive new cluster provisioning requests
- Integration with Common Service Broker disrupted

#### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment -n acm-service-broker acm-service-broker-api
   ```
2. Check pod status:
   ```bash
   oc get pods -n acm-service-broker -l app=acm-service-broker-api
   ```
3. Check pod logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-api --tail=100
   ```
4. Check service endpoints:
   ```bash
   oc get endpoints -n acm-service-broker acm-service-broker-svc
   ```

#### Mitigation
1. Check for resource constraints
2. Verify TLS certificate configuration
3. Check mTLS configuration if enabled
4. Restart failed pods if necessary
5. Verify network policies allow traffic from common-service-broker namespace
6. Escalate to development team if application issue

---

## Operational Alerts

### HighDeploymentFailureRate

#### Meaning
Cluster deployment failure rate exceeds 10% over the last hour.

#### Impact
- High number of failed cluster provisioning attempts
- Potential systemic issue affecting multiple deployments
- Customer impact if failures are widespread

#### Diagnosis
1. Check failure rate:
   ```promql
   rate(sov_caas_service_broker_failure_total{operation="deploy"}[1h])
   / (rate(sov_caas_service_broker_success_total{operation="deploy"}[1h])
      + rate(sov_caas_service_broker_failure_total{operation="deploy"}[1h]))
   ```
2. Check failure breakdown by reason:
   ```promql
   sum by (failure_reason) (rate(sov_caas_service_broker_failure_total{operation="deploy"}[1h]))
   ```
3. List recent failed ClusterRequests:
   ```bash
   oc get clusterrequest -A -o json | jq '.items[] | select(.status.phase=="Failed") | {name: .metadata.name, namespace: .metadata.namespace, reason: .status.conditions[].message}'
   ```

#### Mitigation
1. Identify common failure reasons from metrics
2. Check specific failure reason alerts for detailed guidance
3. Review infrastructure capacity (agents, resources)
4. Check ACM hub cluster health
5. Verify network connectivity
6. Escalate if systemic issue identified

---

### ClusterAsAServiceSlowDeploymentDuration

#### Meaning
95th percentile cluster deployment duration exceeds 2 hours.

#### Impact
- Slower than expected cluster provisioning
- Potential performance degradation
- Customer experience impact

#### Diagnosis
1. Check deployment duration:
   ```promql
   histogram_quantile(0.95, rate(sov_caas_service_broker_duration_seconds_bucket{operation="deploy"}[1h]))
   ```
2. Check currently running deployments:
   ```bash
   oc get clusterrequest -A -o json | jq '.items[] | select(.status.phase | IN("PreChecking", "Provisioning", "Installing", "PostInstall")) | {name: .metadata.name, phase: .status.phase, started: .metadata.annotations["metrics.sovereign.cloud.ibm.com/operation-started"]}'
   ```
3. Check agent availability:
   ```bash
   oc get agents -n infraenv
   ```

#### Mitigation
1. Check infrastructure performance (storage, network)
2. Verify agent resources are not constrained
3. Check ACM hub cluster performance
4. Review OpenShift installation logs for slow phases
5. Consider scaling agent infrastructure if consistently slow

---

### ClusterAsAServiceSlowUndeploymentDuration

#### Meaning
95th percentile cluster undeployment duration exceeds 1 hour.

#### Impact
- Slower than expected cluster deprovisioning
- Potential performance degradation
- Customer experience impact for cluster deletion

#### Diagnosis
1. Check undeployment duration:
   ```promql
   histogram_quantile(0.95, rate(sov_caas_service_broker_duration_seconds_bucket{operation="undeploy"}[1h]))
   ```
2. Check currently running undeployments:
   ```bash
   oc get clusterrequest -A -o json | jq '.items[] | select(.status.phase | IN("Deprovisioning", "Deleting")) | {name: .metadata.name, phase: .status.phase, started: .metadata.annotations["metrics.sovereign.cloud.ibm.com/operation-started"]}'
   ```
3. Check for stuck resources:
   ```bash
   oc get managedcluster -A | grep Terminating
   ```

#### Mitigation
1. Check for stuck finalizers on ManagedCluster resources
2. Verify ACM hub cluster performance
3. Check DNS provider API responsiveness
4. Review certificate deletion processes
5. Check for namespace deletion issues
6. Consider manual cleanup of stuck resources if safe

---

### ClusterAsAServiceHighConcurrentDeployments

#### Meaning
More than 10 cluster deployments are running concurrently.

#### Impact
- High load on infrastructure
- Potential resource contention
- May impact deployment performance

#### Diagnosis
1. Check concurrent operations:
   ```promql
   sov_caas_service_broker_current{operation="deploy"}
   ```
2. List in-progress deployments:
   ```bash
   oc get clusterrequest -A -o json | jq '.items[] | select(.status.phase | IN("PreChecking", "Provisioning", "Installing", "PostInstall")) | {name: .metadata.name, namespace: .metadata.namespace, phase: .status.phase}'
   ```

#### Mitigation
1. Monitor for resource constraints
2. Verify infrastructure can handle load
3. Consider implementing rate limiting if needed
4. This is informational - no immediate action required unless performance degrades

---

### ClusterAsAServiceHighConcurrentUndeployments

#### Meaning
More than 10 cluster undeployments are running concurrently.

#### Impact
- High load on infrastructure during cleanup
- Potential resource contention
- May impact undeployment performance

#### Diagnosis
1. Check concurrent undeployment operations:
   ```promql
   sov_caas_service_broker_current{operation="undeploy"}
   ```
2. List in-progress undeployments:
   ```bash
   oc get clusterrequest -A -o json | jq '.items[] | select(.status.phase | IN("Deprovisioning", "Deleting")) | {name: .metadata.name, namespace: .metadata.namespace, phase: .status.phase}'
   ```

#### Mitigation
1. Monitor for resource constraints during cleanup
2. Verify infrastructure can handle cleanup load
3. Check for stuck deletions that may be blocking others
4. This is informational - no immediate action required unless performance degrades

---

## Failure Reason Specific Alerts

### ClusterDeploymentAgentExhausted

#### Meaning
All agents in the specified agent class are currently in use.

#### Impact
- Cannot provision new clusters until agents become available
- Deployment requests will fail immediately
- Customer impact for new provisioning requests

#### Diagnosis
1. Check agent availability:
   ```bash
   oc get agents -n infraenv -o json | jq '.items[] | {name: .metadata.name, approved: .spec.approved, bound: (.status.debugInfo.state == "bound")}'
   ```
2. Check failed ClusterRequests:
   ```bash
   oc get clusterrequest -A -o json | jq '.items[] | select(.status.conditions[].reason=="AgentExhausted") | {name: .metadata.name, namespace: .metadata.namespace, message: .status.conditions[].message}'
   ```

#### Mitigation
1. Wait for existing deployments to complete and release agents
2. Add more agents to the infrastructure
3. Check if any agents are stuck in bound state
4. Consider implementing agent class prioritization
5. Communicate capacity constraints to users

---

### ClusterDeploymentAgentNotFound

#### Meaning
Agent not found, possibly due to API server unavailability or agent deletion.

#### Impact
- Deployment cannot proceed
- May indicate infrastructure or connectivity issues

#### Diagnosis
1. Check API server connectivity:
   ```bash
   oc get --raw /healthz
   ```
2. Verify agent exists:
   ```bash
   oc get agents -n infraenv
   ```
3. Check controller logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=100 | grep -i agent
   ```

#### Mitigation
1. Verify API server is accessible
2. Check if agent was accidentally deleted
3. Verify network connectivity to agent namespace
4. Check RBAC permissions for agent access
5. Restart controller if transient issue

---

### ClusterDeploymentOSImagesNotFound

#### Meaning
Required OS images do not exist in AgentServiceConfig.

#### Impact
- Cannot provision clusters without OS images
- Configuration issue that affects all deployments

#### Diagnosis
1. Check AgentServiceConfig:
   ```bash
   oc get agentserviceconfig -A -o yaml
   ```
2. Verify OS images are configured:
   ```bash
   oc get agentserviceconfig -A -o json | jq '.items[].spec.osImages'
   ```

#### Mitigation
1. Add required OS images to AgentServiceConfig
2. Verify image URLs are accessible
3. Check ACM documentation for supported OS versions
4. Update AgentServiceConfig with correct images
5. Retry failed deployments after fix

---

### ClusterDeploymentCertificateConfigurationFailed

#### Meaning
Certificate configuration process failed during cluster setup.

#### Impact
- Cluster deployment cannot proceed
- TLS/certificate infrastructure issue

#### Diagnosis
1. Check ClusterRequest status:
   ```bash
   oc get clusterrequest <name> -n <namespace> -o yaml
   ```
2. Check certificate resources:
   ```bash
   oc get certificates -n <cluster-namespace>
   ```
3. Check controller logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=100 | grep -i certificate
   ```

#### Mitigation
1. Verify cert-manager is running properly
2. Check certificate issuer configuration
3. Verify DNS is properly configured
4. Check for certificate quota limits
5. Retry deployment after resolving certificate issues

---

### ClusterDeploymentCertificateDeletionFailed

#### Meaning
Certificate deletion process failed during cluster cleanup.

#### Impact
- Cleanup incomplete
- May leave orphaned certificate resources
- Could affect future deployments with same name

#### Diagnosis
1. Check remaining certificates:
   ```bash
   oc get certificates -A | grep <cluster-name>
   ```
2. Check controller logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=100 | grep -i "certificate.*delet"
   ```

#### Mitigation
1. Manually delete orphaned certificates if safe
2. Verify cert-manager is functioning
3. Check for finalizers blocking deletion
4. May require manual cleanup of certificate resources

---

### ClusterDeploymentDeletionFailed

#### Meaning
Deletion of ManagedCluster, Namespace, or ComplianceRegistration failed.

#### Impact
- Cluster cleanup incomplete
- Resources may be orphaned
- Could affect future deployments

#### Diagnosis
1. Check ManagedCluster status:
   ```bash
   oc get managedcluster <cluster-name> -o yaml
   ```
2. Check namespace deletion:
   ```bash
   oc get namespace <cluster-namespace>
   ```
3. Check for finalizers:
   ```bash
   oc get managedcluster <cluster-name> -o json | jq '.metadata.finalizers'
   ```

#### Mitigation
1. Check for stuck finalizers
2. Manually remove finalizers if safe (with caution)
3. Verify ACM is functioning properly
4. Check RBAC permissions for deletion
5. May require manual cleanup of resources

---

### ClusterDeploymentDNSDeletionFailed

#### Meaning
DNS record deletion failed during cluster cleanup.

#### Impact
- DNS records may remain
- Could cause conflicts with future deployments
- Cleanup incomplete

#### Diagnosis
1. Check DNS provider logs
2. Verify DNS credentials are valid
3. Check controller logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=100 | grep -i dns
   ```

#### Mitigation
1. Manually delete DNS records if possible
2. Verify DNS provider API is accessible
3. Check DNS credentials and permissions
4. Retry deletion if transient issue

---

### ClusterDeploymentComplianceRegistrationFailed

#### Meaning
Compliance registration process failed.

#### Impact
- Cluster may not be properly registered for compliance
- Compliance monitoring may be incomplete

#### Diagnosis
1. Check ComplianceRegistration resources:
   ```bash
   oc get complianceregistration -A
   ```
2. Check controller logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=100 | grep -i compliance
   ```

#### Mitigation
1. Verify compliance service is accessible
2. Check compliance registration configuration
3. Verify network connectivity to compliance service
4. Retry registration if transient issue
5. May require manual compliance registration

---

### ClusterDeploymentInstallationFailed

#### Meaning
AgentClusterInstall failure condition detected during OpenShift installation.

#### Impact
- Cluster installation failed
- Critical failure requiring investigation
- Customer impact

#### Diagnosis
1. Check AgentClusterInstall status:
   ```bash
   oc get agentclusterinstall -n <cluster-namespace> -o yaml
   ```
2. Check installation logs:
   ```bash
   oc logs -n <cluster-namespace> -l app=assisted-installer
   ```
3. Check agent logs:
   ```bash
   oc get agents -n infraenv -o json | jq '.items[] | select(.spec.clusterDeploymentName.name=="<cluster-name>") | .status.debugInfo'
   ```

#### Mitigation
1. Review AgentClusterInstall conditions for specific failure reason
2. Check agent hardware compatibility
3. Verify network configuration (VIPs, DNS)
4. Check for insufficient resources
5. Review OpenShift installation requirements
6. May require redeployment with corrected configuration

---

### ClusterDeploymentError

#### Meaning
General error occurred during cluster deployment.

#### Impact
- Deployment failed
- Requires investigation to determine root cause

#### Diagnosis
1. Check ClusterRequest status:
   ```bash
   oc get clusterrequest <name> -n <namespace> -o yaml
   ```
2. Check controller logs:
   ```bash
   oc logs -n acm-service-broker -l app=acm-service-broker-controller --tail=200
   ```
3. Check all related resources:
   ```bash
   oc get all -n <cluster-namespace>
   ```

#### Mitigation
1. Review error message in ClusterRequest status
2. Check controller logs for detailed error information
3. Verify all prerequisites are met
4. Check for transient issues (network, API server)
5. Retry deployment if transient
6. Escalate to development team with logs if persistent

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check all pods in namespace
oc get pods -n acm-service-broker

# Check pod logs
oc logs -n acm-service-broker <pod-name> --tail=100

# Check pod events
oc describe pod -n acm-service-broker <pod-name>

# Check service endpoints
oc get endpoints -n acm-service-broker
```

### Check Metrics
```bash
# Port-forward to metrics endpoint
oc port-forward -n acm-service-broker svc/acm-service-broker-controller-metrics 8082:8082

# Query metrics
curl -k https://localhost:8082/metrics | grep sov_caas_service_broker
```

### Check ClusterRequest Status
```bash
# List all ClusterRequests
oc get clusterrequest -A

# Get detailed status
oc get clusterrequest <name> -n <namespace> -o yaml

# Check phase and conditions
oc get clusterrequest <name> -n <namespace> -o json | jq '{phase: .status.phase, conditions: .status.conditions}'
```

### Resource Monitoring
```bash
# Check resource usage
oc top pods -n acm-service-broker
oc top nodes

# Check resource limits
oc describe pod -n acm-service-broker <pod-name> | grep -A 5 Limits
```

---

## Additional Resources
- Dashboard: Review Cluster as a Service dashboard
- Application logs: Check centralized logging system