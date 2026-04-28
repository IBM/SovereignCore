# AI Inference as a Service Alerts Runbook

## Overview
This runbook covers alerts related to AI Inference as a Service availability and performance, including:
- AI Inference Service Broker - API service for AI model deployment and provider management
- AI Inference Operator - Kubernetes operator for ModelDeployment resources
- Model Gateway Operator - Kubernetes operator for Provider and Tenant management

---

## AIInferenceAsAServiceOperatorDeploymentDown

### Meaning
The aiiaas-operator deployment has no available replicas.

### Impact
- ModelDeployment management unavailable
- No new AI model deployments can be created
- Existing ModelDeployments cannot be updated or deleted
- Critical service disruption

### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment aiiaas-operator -n aiiaas
   ```
2. Check pod status:
   ```bash
   oc get pods -n aiiaas -l control-plane=controller-manager
   ```
3. Check deployment events:
   ```bash
   oc describe deployment aiiaas-operator -n aiiaas
   ```
4. Check pod logs:
   ```bash
   oc logs -n aiiaas -l control-plane=controller-manager --tail=100 --prefix
   ```

### Mitigation
1. Check for pod failures:
   ```bash
   oc get pods -n aiiaas -l control-plane=controller-manager -o wide
   ```
2. Review pod events for errors:
   ```bash
   oc describe pod -n aiiaas <pod-name>
   ```
3. Check resource constraints:
   ```bash
   oc adm top pods -n aiiaas -l control-plane=controller-manager
   ```
4. Check CRDs:
   ```bash
   oc get crd modeldeployments.sovereign.cloud.ibm.com
   ```
5. Restart deployment if necessary:
   ```bash
   oc rollout restart deployment aiiaas-operator -n aiiaas
   ```

---

## AIInferenceAsAServiceOperatorHighReconcileErrors

### Meaning
The ModelDeployment controller reconcile error rate has exceeded 10% over the last 5 minutes.

### Impact
- Multiple ModelDeployment reconciliation failures
- ModelDeployments may not be properly created or updated
- Service reliability degradation

### Diagnosis
1. List ModelDeployments with issues:
   ```bash
   oc get modeldeployments -A
   ```
3. Check operator logs for errors:
   ```bash
   oc logs -n aiiaas -l control-plane=controller-manager --tail=1000 --prefix | grep -i "error\|failed"
   ```
4. Check ModelDeployment status:
   ```bash
   oc get modeldeployment <name> -n <namespace> -o yaml
   ```

### Mitigation
1. Identify common error patterns from logs
2. Check Policy status on target clusters:
   ```bash
   oc get policy -A | grep aiiaas
   ```
3. Verify Placement is working:
   ```bash
   oc get placement aiiaas-inference -n aiiaas
   oc get placementdecision -n aiiaas
   ```
4. Check target cluster availability:
   ```bash
   oc get managedclusters
   ```
5. Review recent ModelDeployment configuration changes
6. Check for resource quota issues on target clusters

---

## AIInferenceAsAServiceOperatorSlowReconcile

### Meaning
The ModelDeployment controller 95th percentile reconcile time exceeds 30 seconds.

### Impact
- Slow ModelDeployment creation and updates
- Poor user experience
- Potential performance bottleneck

### Diagnosis
1. Check operator resource usage:
   ```bash
   oc adm top pods -n aiiaas -l control-plane=controller-manager
   ```
2. Check operator logs for slow operations:
   ```bash
   oc logs -n aiiaas -l control-plane=controller-manager --tail=500 --prefix | grep -i "slow\|duration"
   ```

### Mitigation
1. Check resource constraints:
   ```bash
   oc describe pod -n aiiaas <operator-pod> | grep -A 5 "Limits\|Requests"
   ```
2. Consider scaling operator resources
3. Review ModelDeployment complexity (number of policies, placements)

---

# AI Inference Service Broker Alerts Runbook

## Overview
This runbook covers alerts related to AI Inference Service Broker availability and performance, specifically for the AI model deployment and provider management service.

---

## AIInferenceAsAServiceBrokerDeploymentDown

### Meaning
The aiiaas-service-broker deployment has no available replicas.

### Impact
- API service unavailable
- Users cannot provision or manage AI model deployments and providers via API
- Critical service disruption

### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment aiiaas-service-broker -n aiiaas
   ```
2. Check pod status:
   ```bash
   oc get pods -n aiiaas -l app=aiiaas-service-broker
   ```
3. Check deployment events:
   ```bash
   oc describe deployment aiiaas-service-broker -n aiiaas
   ```
4. Check pod logs:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=100
   ```

### Mitigation
1. Check for pod failures:
   ```bash
   oc get pods -n aiiaas -l app=aiiaas-service-broker -o wide
   ```
2. Review pod events for errors:
   ```bash
   oc describe pod -n aiiaas <pod-name>
   ```
3. Check resource constraints:
   ```bash
   oc adm top pods -n aiiaas -l app=aiiaas-service-broker
   ```
4. Verify image pull success:
   ```bash
   oc get events -n aiiaas --field-selector involvedObject.name=<pod-name>
   ```
5. Restart deployment if necessary:
   ```bash
   oc rollout restart deployment aiiaas-service-broker -n aiiaas
   ```
7. Scale up if needed:
   ```bash
   oc scale deployment aiiaas-service-broker -n aiiaas --replicas=3
   ```

---

## AIInferenceAsAServiceBrokerHighErrorRate

### Meaning
HTTP error rate (5xx responses) for AI Inference Service Broker has exceeded 5% over the last 5 minutes.

### Impact
- Multiple API request failures
- Service reliability degradation
- User experience impact
- Potential systemic issue

### Diagnosis
1. Check pod logs for errors:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=500 --prefix | grep -i error
   ```
3. Check specific error patterns:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=1000 | grep "status=5" | tail -50
   ```
4. Check service health:
   ```bash
   oc get pods -n aiiaas -l app=aiiaas-service-broker
   ```
5. Check dependent services:
   ```bash
   # Model Gateway operator
   oc get pods -n aiiaas -l app=model-gateway-operator

   # Quay registry
   oc get pods -n quay-enterprise

   # IAM service
   oc get pods -n msp-user-manager -l app.kubernetes.io/name=account-iam
   ```

### Mitigation
1. Identify error patterns from logs
2. Check resource availability:
   ```bash
   oc adm top pods -n aiiaas
   oc describe node | grep -A 5 "Allocated resources"
   ```
5. Review recent configuration changes
6. If persistent, restart deployment:
   ```bash
   oc rollout restart deployment aiiaas-service-broker -n aiiaas
   ```

---

## AIInferenceAsAServiceBrokerSlowOperations

### Meaning
Average operation duration for AI Inference Service Broker exceeds 30 seconds over the last 10 minutes.

### Impact
- Delayed AI model deployment and provider provisioning
- Poor user experience
- Potential resource bottleneck or configuration issue

### Diagnosis
1. Check audit logs for slow API requests:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=1000 | grep "latency=" | awk '{for(i=1;i<=NF;i++){if($i~/latency=/){print $i}}}' | sort -t= -k2 -n | tail -20
   ```
2. Identify slow endpoints from audit logs:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=1000 | grep "latency=" | awk '{for(i=1;i<=NF;i++){if($i~/path=/ || $i~/latency=/){printf "%s ", $i}} print ""}' | sort -t= -k4 -n | tail -20
   ```
3. Check ModelDeployment and Provider resources:
   ```bash
   oc get modeldeployments -A
   oc get providers -A
   ```

### Mitigation
1. Check target cluster availability:
   ```bash
   oc get managedclusters
   ```
2. Check policy compliance:
   ```bash
   oc get policy -A | grep aiiaas
   ```
4. Review resource availability on target clusters
5. Monitor ongoing operations:
   ```bash
   oc get modeldeployments -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
   ```

---

## AIInferenceAsAServiceBrokerLowSuccessRate

### Meaning
The success rate for AI Inference Service Broker operations has fallen below 90% over the last 5 minutes.

### Impact
- Multiple operation failures
- Service reliability degradation
- Widespread user impact
- Potential systemic issue

### Diagnosis
1. Check failed operations:
   ```bash
   oc get modeldeployments -A -o jsonpath='{range .items[?(@.status.phase=="Failed")]}{.metadata.name}{"\t"}{.status.message}{"\n"}{end}'
   oc get providers -A -o jsonpath='{range .items[?(@.status.phase=="Failed")]}{.metadata.name}{"\t"}{.status.message}{"\n"}{end}'
   ```
3. Review failure patterns in logs:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=1000 --prefix | grep -i "error\|failed" | tail -50
   ```

### Mitigation
1. Identify common failure patterns
2. Check dependent service health:
   ```bash
   # Model Gateway operator
   oc get pods -n aiiaas -l app=model-gateway-operator

   # Quay registry
   oc get pods -n quay-enterprise
   ```
3. Check resource quotas:
   ```bash
   oc get resourcequota -A
   ```
5. Review recent configuration changes
6. If systemic issue identified, consider temporary service pause

---

## AIInferenceAsAServiceBrokerMeteringCollectionFailed

### Meaning
The last successful metering collection was more than 2 hours ago.

### Impact
- Metering data not being collected
- Potential billing/usage tracking issues
- Data gaps in usage reports

### Diagnosis
1. Check metering collector logs:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=500 --prefix | grep -i "metering"
   ```
3. Check MeteringCollectorState resources:
   ```bash
   oc get meteringcollectorstates -A
   ```
4. Check leader election status:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=200 | grep -i "leader"
   ```

### Mitigation
1. Check pod status and restart if needed:
   ```bash
   oc get pods -n aiiaas -l app=aiiaas-service-broker
   oc rollout restart deployment aiiaas-service-broker -n aiiaas
   ```
2. Check for errors in MeteringCollectorState:
   ```bash
   oc get meteringcollectorstates -A -o yaml
   ```

---

## AIInferenceAsAServiceBrokerHighLatency

### Meaning
The 95th percentile latency for HTTP requests exceeds 5 seconds.

### Impact
- Slow API response times
- Poor user experience
- Potential performance bottleneck

### Diagnosis
1. Check pod resource usage:
   ```bash
   oc adm top pods -n aiiaas -l app=aiiaas-service-broker
   ```
4. Check for slow operations in logs:
   ```bash
   oc logs -n aiiaas -l app=aiiaas-service-broker --tail=500 --prefix | grep -i "slow\|timeout"
   ```

### Mitigation
1. Check resource constraints:
   ```bash
   oc describe pod -n aiiaas <pod-name> | grep -A 5 "Limits\|Requests"
   ```
2. Check for CPU/memory throttling:
   ```bash
   oc adm top pods -n aiiaas
   ```
3. Consider scaling up resources:
   ```bash
   oc scale deployment aiiaas-service-broker -n aiiaas --replicas=3
   ```
6. Review and optimize slow API endpoints

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check all pods in namespace
oc get pods -n aiiaas

# Check service broker pods
oc get pods -n aiiaas -l app=aiiaas-service-broker

# Check pod logs
oc logs -n aiiaas <pod-name> --tail=100

# Check pod events
oc describe pod -n aiiaas <pod-name>

# Check service endpoints
oc get endpoints -n aiiaas
```

### Check Metrics
```bash
# Port forward to metrics endpoint
oc port-forward -n aiiaas svc/aiiaas-service-broker 8082:8082

# Query metrics
curl http://localhost:8082/metrics | grep aiiaas

# Check specific metrics
curl http://localhost:8082/metrics | grep aiiaas_broker_http_request_duration_seconds
curl http://localhost:8082/metrics | grep aiiaas_broker_operation_duration_seconds
curl http://localhost:8082/metrics | grep aiiaas_metering
```

### Check ModelDeployment Status
```bash
# List all model deployments
oc get modeldeployments -A

# Get detailed status
oc get modeldeployment <name> -n <namespace> -o yaml

# Check phase
oc get modeldeployment <name> -n <namespace> -o jsonpath='{.status.phase}'

# Check conditions
oc get modeldeployment <name> -n <namespace> -o jsonpath='{.status.conditions}' | jq
```

### Check Provider Status
```bash
# List all providers
oc get providers -A

# Get detailed status
oc get provider <name> -n <namespace> -o yaml

# Check phase
oc get provider <name> -n <namespace> -o jsonpath='{.status.phase}'
```

### Check Dependent Services
```bash
# Model Gateway operator
oc get pods -n aiiaas -l app=model-gateway-operator

# Quay registry
oc get pods -n quay-enterprise

# IAM service
oc get pods -n msp-user-manager -l app.kubernetes.io/name=account-iam
```

### Resource Monitoring
```bash
# Check resource usage
oc adm top pods -n aiiaas
oc adm top nodes

# Check resource limits
oc describe pod -n aiiaas <pod-name> | grep -A 5 Limits

# Check resource requests
oc describe pod -n aiiaas <pod-name> | grep -A 5 Requests
```

### Check Configuration
```bash
# Check ConfigMap
oc get configmap aiiaas-service-broker-config -n aiiaas -o yaml
```

---

## AIInferenceAsAServiceModelGatewayOperatorDeploymentDown

### Meaning
The model-gateway-operator deployment has no available replicas.

### Impact
- Provider and Tenant management unavailable
- No new AI model providers can be registered
- Existing tenants cannot be managed
- Critical service disruption

### Diagnosis
1. Check deployment status:
   ```bash
   oc get deployment model-gateway-operator -n aiiaas
   ```
2. Check pod status:
   ```bash
   oc get pods -n aiiaas -l app=model-gateway-operator
   ```
3. Check deployment events:
   ```bash
   oc describe deployment model-gateway-operator -n aiiaas
   ```
4. Check pod logs:
   ```bash
   oc logs -n aiiaas -l app=model-gateway-operator --tail=100 --prefix
   ```

### Mitigation
1. Check for pod failures:
   ```bash
   oc get pods -n aiiaas -l app=model-gateway-operator -o wide
   ```
2. Review pod events for errors:
   ```bash
   oc describe pod -n aiiaas <pod-name>
   ```
3. Check resource constraints:
   ```bash
   oc adm top pods -n aiiaas -l app=model-gateway-operator
   ```
4. Check CRDs:
   ```bash
   oc get crd providers.modelgateway.ibm.com
   oc get crd tenants.modelgateway.ibm.com
   ```
5. Restart deployment if necessary:
   ```bash
   oc rollout restart deployment model-gateway-operator -n aiiaas
   ```

---

## AIInferenceAsAServiceModelGatewayEndpointNotConfigured

### Meaning
The Model Gateway endpoint configuration is missing or invalid.

### Impact
- Tenants cannot be created or updated
- Provider synchronization may fail
- Model Gateway integration unavailable

### Diagnosis
1. Check ConfigMap:
   ```bash
   oc get configmap model-gateway-endpoint -n aiiaas
   oc describe configmap model-gateway-endpoint -n aiiaas
   ```
2. Check operator logs:
   ```bash
   oc logs -n aiiaas -l app=model-gateway-operator --tail=200 --prefix | grep -i "endpoint\|gateway"
   ```

### Mitigation
1. Verify ConfigMap exists and has correct data:
   ```bash
   oc get configmap model-gateway-endpoint -n aiiaas -o yaml
   ```
2. Check ConfigMap format (should contain endpoint URL):
   ```bash
   oc get configmap model-gateway-endpoint -n aiiaas -o jsonpath='{.data}'
   ```
3. If missing, create or update ConfigMap:
   ```bash
   oc create configmap model-gateway-endpoint -n aiiaas --from-literal=endpoint=https://model-gateway.example.com
   ```
4. Restart operator to pick up changes:
   ```bash
   oc rollout restart deployment model-gateway-operator -n aiiaas
   ```

---

## AIInferenceAsAServiceModelGatewayProviderSyncFailed

### Meaning
Provider has not synced successfully for over 1 hour.

### Impact
- Provider models may be outdated
- New models not available
- Model metadata may be stale

### Diagnosis
1. List providers:
   ```bash
   oc get providers -A
   ```
3. Check specific provider status:
   ```bash
   oc get provider <provider-name> -n <namespace> -o yaml
   ```
4. Check operator logs for sync errors:
   ```bash
   oc logs -n aiiaas -l app=model-gateway-operator --tail=500 --prefix | grep -i "provider\|sync"
   ```

### Mitigation
1. Check provider configuration:
   ```bash
   oc describe provider <provider-name> -n <namespace>
   ```
2. Check for authentication issues (API keys, credentials)
3. Review provider status conditions:
   ```bash
   oc get provider <provider-name> -n <namespace> -o jsonpath='{.status.conditions}' | jq
   ```
4. Force reconciliation by updating provider:
   ```bash
   oc annotate provider <provider-name> -n <namespace> reconcile=true --overwrite
   ```

---

## AIInferenceAsAServiceModelGatewayProviderSyncSlow

### Meaning
Average Provider sync duration exceeds 30 seconds.

### Impact
- Slow model catalog updates
- Delayed provider information
- Potential performance bottleneck

### Diagnosis
1. Check operator resource usage:
   ```bash
   oc adm top pods -n aiiaas -l app=model-gateway-operator
   ```
2. Check operator logs for slow operations:
   ```bash
   oc logs -n aiiaas -l app=model-gateway-operator --tail=500 --prefix | grep -i "duration\|slow"
   ```

### Mitigation
1. Check resource constraints:
   ```bash
   oc describe pod -n aiiaas <operator-pod> | grep -A 5 "Limits\|Requests"
   ```
2. Consider scaling operator resources
3. Review provider configuration for optimization opportunities

---

## AIInferenceAsAServiceModelGatewayProviderSyncLowSuccessRate

### Meaning
The success rate for Provider sync operations has fallen below 90% over the last 5 minutes.

### Impact
- Multiple provider sync failures
- Incomplete model catalogs
- Service reliability degradation

### Diagnosis
1. List providers with issues:
   ```bash
   # Note: Requires jq for complex filtering
   oc get providers -A -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="False")) | "\(.metadata.name)\t\(.metadata.namespace)"'
   ```
2. Check operator logs for errors:
   ```bash
   oc logs -n aiiaas -l app=model-gateway-operator --tail=1000 --prefix | grep -i "error\|failed"
   ```

### Mitigation
1. Identify common failure patterns from logs
2. Check provider endpoint availability:
   ```bash
   # List all providers with their endpoints
   oc get providers -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,ENDPOINT:.spec.endpoint
   ```
3. Verify authentication credentials for providers
4. Check for network connectivity issues
5. Review recent provider configuration changes
6. If systemic issue identified, consider temporary provider pause

---

## Model Gateway Troubleshooting

### Check Provider Status
```bash
# List all providers
oc get providers -A

# Get detailed provider status
oc get provider <name> -n <namespace> -o yaml

# Check provider conditions
oc get provider <name> -n <namespace> -o jsonpath='{.status.conditions}' | jq

# Check provider models
oc get provider <name> -n <namespace> -o jsonpath='{.status.models}' | jq
```

### Check Tenant Status
```bash
# List all tenants
oc get tenants -A

# Get detailed tenant status
oc get tenant <name> -n <namespace> -o yaml

# Check tenant conditions
oc get tenant <name> -n <namespace> -o jsonpath='{.status.conditions}' | jq
```

### Check Operator Metrics
```bash
# Port forward to metrics endpoint
oc port-forward -n aiiaas svc/model-gateway-operator-metrics-service 8080:8443

# Query metrics (note: HTTPS with self-signed cert)
curl -k https://localhost:8080/metrics | grep modelgateway

# Check specific metrics
curl -k https://localhost:8080/metrics | grep modelgateway_provider_sync_duration_seconds
curl -k https://localhost:8080/metrics | grep modelgateway_tenant_total
curl -k https://localhost:8080/metrics | grep modelgateway_model_total
curl -k https://localhost:8080/metrics | grep modelgateway_gateway_endpoint_configured
```

### Check Gateway Endpoint Configuration
```bash
# Check ConfigMap
oc get configmap model-gateway-endpoint -n openshift-ai-inference -o yaml
```

### Check TLS Certificates
```bash
# Check TLS certificates
oc get secret aiiaas-service-broker-tls -n aiiaas
```
