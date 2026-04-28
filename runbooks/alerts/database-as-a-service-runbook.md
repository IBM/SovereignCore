# Database as a Service Alerts Runbook

## Overview
This runbook covers alerts related to Database as a Service (DBaaS) availability and performance, specifically for the PostgreSQL Operator provisioning service.

---

## DatabaseAsAServicePGOperatorDeploymentUnavailable


### Meaning
The postgres-service-broker-api or postgres-service-broker-controller deployment has no available replicas for more than 30 minutes.

### Impact
- Database as a Service unavailable
- Users cannot provision PostgreSQL operators
- Critical service disruption affecting all DBaaS operations

### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment -n postgres-service-broker
   oc describe deployment postgres-service-broker-api -n postgres-service-broker
   oc describe deployment postgres-service-broker-controller -n postgres-service-broker
   ```
2. Check pod status:
   ```bash
   oc get pods -n postgres-service-broker
   oc describe pod -l app=postgres-service-broker-api -n postgres-service-broker
   oc describe pod -l app=postgres-service-broker-controller -n postgres-service-broker
   ```
3. Check pod logs for errors:
   ```bash
   oc logs -n postgres-service-broker -l app=postgres-service-broker-api --tail=100
   oc logs -n postgres-service-broker -l component=controller --tail=100
   ```
4. Check replica metrics:
   ```promql
   kube_deployment_status_replicas_available{namespace="postgres-service-broker",deployment=~"postgres-service-broker-api|postgres-service-broker-controller"}
   ```
5. Check events:
   ```bash
   oc get events -n postgres-service-broker --sort-by='.lastTimestamp'
   ```

### Mitigation
1. Check for pod failures:
   ```bash
   oc get pods -n postgres-service-broker -o wide
   ```
2. Review pod events for errors:
   ```bash
   oc describe pod -n postgres-service-broker <pod-name>
   ```
3. Check for resource constraints (CPU/memory):
   ```bash
   oc top pods -n postgres-service-broker
   oc describe pod -n postgres-service-broker <pod-name> | grep -A 5 Limits
   ```
4. Verify image pull success:
   ```bash
   oc get events -n postgres-service-broker --field-selector involvedObject.name=<pod-name>
   ```
5. Restart deployment if necessary:
   ```bash
   oc rollout restart deployment postgres-service-broker-api -n postgres-service-broker
   oc rollout restart deployment postgres-service-broker-controller -n postgres-service-broker
   ```
6. Scale up if needed:
   ```bash
   oc scale deployment postgres-service-broker-api -n postgres-service-broker --replicas=2
   oc scale deployment postgres-service-broker-controller -n postgres-service-broker --replicas=2
   ```

---

## DatabaseAsAServicePGOperatorLowSuccessRate

### Meaning
PostgreSQL Operator deployment success rate has fallen below 90% over the last 30 minutes.

### Impact
- Multiple provisioning failures
- Service reliability degradation
- Widespread user impact
- Potential systemic issue

### Diagnosis
1. Check success rate metrics:
   ```promql
   rate(sov_dbaas_postgres_operator_success_total{operation="deploy"}[5m]) / rate(sov_dbaas_postgres_operator_duration_seconds_count{operation="deploy"}[5m])
   ```
2. List failed requests:
   ```bash
   oc get postgresoperatorrequest -A --field-selector status.phase=Failed
   ```
3. Review failure reasons:
   ```bash
   oc get postgresoperatorrequest -A -o jsonpath='{range .items[?(@.status.phase=="Failed")]}{.metadata.name}{"\t"}{.status.message}{"\n"}{end}'
   ```
4. Check for common failure patterns:
   ```bash
   oc get postgresoperatorrequest -A -o json | jq -r '.items[] | select(.status.phase=="Failed") | .status.conditions[] | select(.status=="False") | .type' | sort | uniq -c
   ```
5. Review controller logs for errors:
   ```bash
   oc logs -n postgres-service-broker -l component=controller --tail=500 | grep -i error
   ```

### Mitigation
1. Identify common failure patterns (policy, VIP, MetalLB, etc.)
2. Check policy compliance issues across clusters:
   ```bash
   oc get policy -A | grep postgres-operator | grep -v Compliant
   ```
3. Verify resource availability on target clusters
4. Review recent configuration changes or deployments
5. Check for infrastructure issues (network, storage, etc.)
6. If systemic issue identified, consider temporary service pause
7. Escalate to development team for persistent widespread failures

---

## DatabaseAsAServicePGOperatorHighDuration

### Meaning
PostgreSQL Operator deployment is taking longer than 10 minutes on average over the last 30 minutes.

### Impact
- Delayed PostgreSQL operator provisioning
- Poor user experience
- Potential resource bottleneck or configuration issue

### Diagnosis
1. Check request status:
   ```bash
   oc get postgresoperatorrequest -A
   oc describe postgresoperatorrequest <name> -n postgres-service-broker
   ```
2. Check current phase and conditions:
   ```bash
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.phase}'
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions}' | jq
   ```
3. Check deployment duration metric:
   ```promql
   sov_dbaas_postgres_operator_duration_seconds{operation="deploy"}
   ```
4. Review controller logs:
   ```bash
   oc logs -n postgres-service-broker -l component=controller --tail=200 | grep <request-name>
   ```
5. Check target ManagedCluster status:
   ```bash
   oc get managedcluster <cluster-name>
   oc describe managedcluster <cluster-name>
   ```

### Mitigation
1. Check policy compliance on target cluster:
   ```bash
   oc get policy -A | grep postgres-operator
   oc describe policy <policy-name> -n postgres-service-broker
   ```
2. Verify ManagedCluster is available and healthy
3. Review MetalLB installation status if external access is enabled:
   ```bash
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions[?(@.type=="MetalLBInstalled")]}'
   ```
4. Check VIP allocation if IPAM is enabled:
   ```bash
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions[?(@.type=="VIPAllocated")]}'
   ```
5. Review resource availability on target cluster
6. Check controller performance:
   ```bash
   oc top pods -l component=controller -n postgres-service-broker
   ```
7. If stuck in Creating phase for extended period, consider manual intervention or escalation

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check all pods in namespace
oc get pods -n postgres-service-broker

# Check API server pods
oc get pods -n postgres-service-broker -l app=postgres-service-broker-api

# Check controller pods
oc get pods -n postgres-service-broker -l component=controller

# Check pod logs
oc logs -n postgres-service-broker <pod-name> --tail=100

# Check pod events
oc describe pod -n postgres-service-broker <pod-name>

# Check service endpoints
oc get endpoints -n postgres-service-broker
```

### Check Controller Metrics
```bash
# Port forward to metrics endpoint
oc port-forward -n postgres-service-broker svc/postgres-service-broker-controller-metrics 8082:8082

# Query metrics
curl http://localhost:8082/metrics | grep sov_dbaas_postgres_operator

# Check specific metrics
curl http://localhost:8082/metrics | grep sov_dbaas_postgres_operator_duration_seconds
curl http://localhost:8082/metrics | grep sov_dbaas_postgres_operator_success_total
curl http://localhost:8082/metrics | grep sov_dbaas_postgres_operator_current
```

### Check PostgresOperatorRequest Status
```bash
# List all requests
oc get postgresoperatorrequest -A

# Get detailed status
oc get postgresoperatorrequest <name> -n postgres-service-broker -o yaml

# Check phase
oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.phase}'

# Check all conditions
oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions}' | jq

# Check specific condition
oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions[?(@.type=="VIPAllocated")]}'
```

### Check Policy Status
```bash
# List all postgres-operator policies
oc get policy -A | grep postgres-operator

# Check specific policy
oc describe policy <policy-name> -n postgres-service-broker

# Check policy compliance
oc get policy <policy-name> -n postgres-service-broker -o jsonpath='{.status.compliant}'

# Check placement decisions
oc get placementdecision -n postgres-service-broker
```

### Check ManagedCluster
```bash
# Get cluster
oc get managedcluster <cluster-name>

# Check cluster labels
oc get managedcluster <cluster-name> -o jsonpath='{.metadata.labels}'

# Check cluster status
oc describe managedcluster <cluster-name>
```

### Resource Monitoring
```bash
# Check resource usage
oc top pods -n postgres-service-broker
oc top nodes

# Check resource quotas
oc get resourcequota -A
oc get limitrange -A
```

---

## Additional Resources

- [PostgreSQL Operator Documentation](https://postgres-operator.readthedocs.io/)
- [Kubernetes Troubleshooting Guide](https://kubernetes.io/docs/tasks/debug/)
- [OpenShift Troubleshooting Guide](https://docs.openshift.com/container-platform/latest/support/troubleshooting/troubleshooting-installations.html)
### Meaning
The postgres-service-broker-api deployment has no available replicas.

### Impact
- API service unavailable
- Users cannot provision or manage PostgreSQL operators via API
- Critical service disruption

### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment postgres-service-broker-api -n postgres-service-broker
   ```
2. Check pod status:
   ```bash
   oc get pods -n postgres-service-broker -l app=postgres-service-broker-api
   ```
3. Check deployment events:
   ```bash
   oc describe deployment postgres-service-broker-api -n postgres-service-broker
   ```
4. Check pod logs:
   ```bash
   oc logs -n postgres-service-broker -l app=postgres-service-broker-api --tail=100
   ```
5. Check replica metrics:
   ```promql
   kube_deployment_status_replicas_available{namespace="postgres-service-broker",deployment="postgres-service-broker-api"}
   ```

### Mitigation
1. Check for pod failures:
   ```bash
   oc get pods -n postgres-service-broker -l app=postgres-service-broker-api -o wide
   ```
2. Review pod events for errors:
   ```bash
   oc describe pod -n postgres-service-broker <pod-name>
   ```
3. Check resource constraints:
   ```bash
   oc top pods -n postgres-service-broker -l app=postgres-service-broker-api
   ```
4. Verify image pull success:
   ```bash
   oc get events -n postgres-service-broker --field-selector involvedObject.name=<pod-name>
   ```
5. Restart deployment if necessary:
   ```bash
   oc rollout restart deployment postgres-service-broker-api -n postgres-service-broker
   ```
6. Scale up if needed:
   ```bash
   oc scale deployment postgres-service-broker-api -n postgres-service-broker --replicas=2
   ```

---

## DatabaseAsAServiceControllerDeploymentDown

### Meaning
The postgres-service-broker-controller deployment has no available replicas.

### Impact
- PostgreSQL Operator provisioning unavailable
- No new operator deployments can be processed
- Existing PostgresOperatorRequests stuck in processing
- Critical service disruption

### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment postgres-service-broker-controller -n postgres-service-broker
   ```
2. Check pod status:
   ```bash
   oc get pods -n postgres-service-broker -l component=controller
   ```
3. Check deployment events:
   ```bash
   oc describe deployment postgres-service-broker-controller -n postgres-service-broker
   ```
4. Check pod logs:
   ```bash
   oc logs -n postgres-service-broker -l component=controller --tail=100
   ```
5. Check replica metrics:
   ```promql
   kube_deployment_status_replicas_available{namespace="postgres-service-broker",deployment="postgres-service-broker-controller"}
   ```

### Mitigation
1. Check for pod failures:
   ```bash
   oc get pods -n postgres-service-broker -l component=controller -o wide
   ```
2. Review pod events for errors:
   ```bash
   oc describe pod -n postgres-service-broker <pod-name>
   ```
3. Check resource constraints:
   ```bash
   oc top pods -n postgres-service-broker -l component=controller
   ```
4. Verify RBAC permissions:
   ```bash
   oc get clusterrole,clusterrolebinding -l app=postgres-service-broker
   ```
5. Check controller metrics endpoint:
   ```bash
   oc port-forward -n postgres-service-broker svc/postgres-service-broker-controller-metrics 8082:8082
   curl https://localhost:8082/metrics -k
   ```
6. Restart deployment if necessary:
   ```bash
   oc rollout restart deployment postgres-service-broker-controller -n postgres-service-broker
   ```
7. Scale up if needed:
   ```bash
   oc scale deployment postgres-service-broker-controller -n postgres-service-broker --replicas=2
   ```

---

## DatabaseAsAServicePGOperatorDeploymentSlow

### Meaning
PostgreSQL Operator deployment is taking longer than 30 minutes.

### Impact
- Delayed PostgreSQL operator provisioning
- Poor user experience
- Potential resource bottleneck or configuration issue

### Diagnosis
1. Check request status:
   ```bash
   oc get postgresoperatorrequest -n postgres-service-broker
   oc describe postgresoperatorrequest <name> -n postgres-service-broker
   ```
2. Check current phase and conditions:
   ```bash
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.phase}'
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions}' | jq
   ```
3. Check deployment duration metric:
   ```promql
   sov_dbaas_postgres_operator_duration_seconds{operation="deploy"}
   ```
4. Review controller logs:
   ```bash
   oc logs -n postgres-service-broker -l component=controller --tail=200 | grep <request-name>
   ```
5. Check target ManagedCluster status:
   ```bash
   oc get managedcluster <cluster-name>
   oc describe managedcluster <cluster-name>
   ```

### Mitigation
1. Check policy compliance on target cluster:
   ```bash
   oc get policy -A | grep postgres-operator
   oc describe policy <policy-name> -n postgres-service-broker
   ```
2. Verify ManagedCluster is available and healthy
3. Review MetalLB installation status if external access is enabled:
   ```bash
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions[?(@.type=="MetalLBInstalled")]}'
   ```
4. Check VIP allocation if IPAM is enabled:
   ```bash
   oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions[?(@.type=="VIPAllocated")]}'
   ```
5. Review resource availability on target cluster
6. If stuck in Creating phase for extended period, consider manual intervention or escalation

---

## DatabaseAsAServicePGOperatorLowSuccessRate

### Meaning
PostgreSQL Operator deployment success rate has fallen below 90% over the last 5 minutes.

### Impact
- Multiple provisioning failures
- Service reliability degradation
- Widespread user impact
- Potential systemic issue

### Diagnosis
1. Check success rate metrics:
   ```promql
   rate(sov_dbaas_postgres_operator_success_total{operation="deploy"}[5m])
   rate(sov_dbaas_postgres_operator_duration_seconds_count{operation="deploy"}[5m])
   rate(sov_dbaas_postgres_operator_success_total{operation="deploy"}[5m]) / rate(sov_dbaas_postgres_operator_duration_seconds_count{operation="deploy"}[5m])
   ```
2. List failed requests:
   ```bash
   oc get postgresoperatorrequest -A --field-selector status.phase=Failed
   ```
3. Review failure reasons:
   ```bash
   oc get postgresoperatorrequest -A -o jsonpath='{range .items[?(@.status.phase=="Failed")]}{.metadata.name}{"\t"}{.status.message}{"\n"}{end}'
   ```
4. Check for common failure patterns:
   ```bash
   oc get postgresoperatorrequest -A -o json | jq -r '.items[] | select(.status.phase=="Failed") | .status.conditions[] | select(.status=="False") | .type' | sort | uniq -c
   ```
5. Review controller logs for errors:
   ```bash
   oc logs -n postgres-service-broker -l component=controller --tail=500 | grep -i error
   ```

### Mitigation
1. Identify common failure patterns (policy, VIP, MetalLB, etc.)
2. Check policy compliance issues across clusters:
   ```bash
   oc get policy -A | grep postgres-operator | grep -v Compliant
   ```
3. Verify resource availability on target clusters
4. Review recent configuration changes or deployments
5. Check for infrastructure issues (network, storage, etc.)
6. If systemic issue identified, consider temporary service pause
7. Escalate to development team for persistent widespread failures

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check all pods in namespace
oc get pods -n postgres-service-broker

# Check API server pods
oc get pods -n postgres-service-broker -l app=postgres-service-broker-api

# Check controller pods
oc get pods -n postgres-service-broker -l component=controller

# Check pod logs
oc logs -n postgres-service-broker <pod-name> --tail=100

# Check pod events
oc describe pod -n postgres-service-broker <pod-name>

# Check service endpoints
oc get endpoints -n postgres-service-broker
```

### Check HAProxy Metrics
```bash
# View HAProxy stats
oc exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats

# Check backend health
oc exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats | grep postgres-service-broker
```

### Check Controller Metrics
```bash
# Port forward to metrics endpoint
oc port-forward -n postgres-service-broker svc/postgres-service-broker-controller-metrics 8082:8082

# Query metrics
curl http://localhost:8082/metrics | grep postgres_operator_request

# Check specific metrics
curl http://localhost:8082/metrics | grep postgres_operator_request_duration_seconds
curl http://localhost:8082/metrics | grep postgres_operator_request_total
```

### Check PostgresOperatorRequest Status
```bash
# List all requests
oc get postgresoperatorrequest -n postgres-service-broker

# Get detailed status
oc get postgresoperatorrequest <name> -n postgres-service-broker -o yaml

# Check phase
oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.phase}'

# Check all conditions
oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions}' | jq

# Check specific condition
oc get postgresoperatorrequest <name> -n postgres-service-broker -o jsonpath='{.status.conditions[?(@.type=="VIPAllocated")]}'
```

### Check Policy Status
```bash
# List all postgres-operator policies
oc get policy -A | grep postgres-operator

# Check specific policy
oc describe policy <policy-name> -n postgres-service-broker

# Check policy compliance
oc get policy <policy-name> -n postgres-service-broker -o jsonpath='{.status.compliant}'

# Check placement decisions
oc get placementdecision -n postgres-service-broker
```

### Check ManagedCluster
```bash
# Get cluster
oc get managedcluster <cluster-name>

# Check cluster labels
oc get managedcluster <cluster-name> -o jsonpath='{.metadata.labels}'

# Check cluster status
oc describe managedcluster <cluster-name>
```

### Resource Monitoring
```bash
# Check resource usage
oc top pods -n postgres-service-broker
oc top nodes

# Check resource limits
oc describe pod -n postgres-service-broker <pod-name> | grep -A 5 Limits

# Check resource requests
oc describe pod -n postgres-service-broker <pod-name> | grep -A 5 Requests
```

### Check IPAM Integration (if enabled)
```bash
# Check VIP ConfigMap
oc get configmap -n postgres-service-broker | grep vip

# Check VIP allocation
oc get configmap <vip-configmap> -n postgres-service-broker -o yaml
```

---

## Additional Resources
- PostgreSQL Operator documentation
- Application logs: Check centralized logging system
- ACM Policy documentation: For policy troubleshooting
- MetalLB documentation: For load balancer issues