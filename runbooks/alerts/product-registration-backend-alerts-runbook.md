# Product Registration Backend Alerts Runbook

## Overview
This runbook covers alerts related to Product Registration backend service availability and performance.

---

## ProductRegistrationBackendDown

### Meaning
The HAProxy backend for Product Registration service is down.

### Impact
- Product Registration service unavailable
- Users cannot register new products
- Critical business function disrupted

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="product-registration"}) by (route) == 0
   ```
2. Verify pod status:
   ```bash
   kubectl get pods -n product-registration
   ```
3. Check pod logs:
   ```bash
   kubectl logs -n product-registration <pod-name>
   ```
4. Check service configuration
5. Verify ProductRegistrationV2 CRs:
   ```bash
   kubectl get productregistrationv2s -A
   ```

### Mitigation
1. Restart failed pods
2. Check for resource exhaustion
3. Review application logs for errors
4. Verify ProductRegistrationV2 CRs are properly configured
5. Rollback recent changes if necessary

---

## ProductRegistrationHighErrorRate

### Meaning
Product Registration service is experiencing more than 5% error rate (5xx responses).

### Impact
- Service reliability degraded
- User operations failing
- Potential data integrity issues

### Diagnosis
1. Check error rate:
   ```promql
   sum(irate(haproxy_backend_http_responses_total{exported_namespace="product-registration",code="5xx"}[5m])) / sum(irate(haproxy_backend_http_responses_total{exported_namespace="product-registration"}[5m])) > 0.05
   ```
2. Review application logs for error patterns
3. Verify external service dependencies (marketplace, OCM, etc.)
4. Check ProductRegistrationV2 CR status
5. Review recent code deployments

### Mitigation
1. Identify and fix root cause of errors
2. Rollback recent deployments if necessary
3. Fix connectivity to external dependencies
4. Implement circuit breakers for failing dependencies
5. Scale resources if needed

---

## ProductRegistrationHighLatency

### Meaning
Product Registration service average response latency has exceeded 500ms for 10 minutes.

### Impact
- Poor user experience
- Potential timeout issues
- Reduced throughput

### Diagnosis
1. Check latency metrics:
   ```promql
   sum(haproxy_backend_http_average_response_latency_milliseconds{exported_namespace="product-registration"}) by (route) > 500
   ```
2. Identify slow endpoints
3. Check for resource constraints (CPU/memory)
4. Verify external service response times
5. Analyze application performance metrics

### Mitigation
1. Optimize slow API calls to external services
2. Implement caching strategies
3. Scale application resources
4. Review and optimize code paths
5. Tune timeout and retry configurations

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check pod status
kubectl get pods -n product-registration

# Check pod logs
kubectl logs -n product-registration <pod-name> --tail=100

# Check pod events
kubectl describe pod -n product-registration <pod-name>

# Check service endpoints
kubectl get endpoints -n product-registration
```

### Check HAProxy Metrics
HAProxy runs in the `openshift-ingress` namespace as the router pods.

```bash
# List HAProxy router pods
kubectl get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default

# View HAProxy stats (replace <router-pod-name> with actual pod name from above)
kubectl exec -n openshift-ingress <router-pod-name> -- curl localhost:1936/stats

# Check backend health for product-registration
kubectl exec -n openshift-ingress <router-pod-name> -- curl localhost:1936/stats | grep product-registration
```

**Note:** Router pod names follow the pattern `router-default-<hash>-<hash>`. Use the first command to get current pod names.

### Check ProductRegistrationV2 Custom Resources
```bash
# List all ProductRegistrationV2 CRs
kubectl get productregistrationv2s -A

# Describe a specific CR
kubectl describe productregistrationv2 <cr-name> -n <namespace>

# Check CR status
kubectl get productregistrationv2 <cr-name> -n <namespace> -o yaml
```

### Check External Service Connectivity
```bash
# Test connectivity to marketplace/OCM endpoints
kubectl exec -n product-registration <pod-name> -- curl -v <external-endpoint>

# Check network policies
kubectl get networkpolicies -n product-registration
```

### Resource Monitoring
```bash
# Check resource usage
kubectl top pods -n product-registration
kubectl top nodes

# Check resource limits
kubectl describe pod -n product-registration <pod-name> | grep -A 5 Limits
```

---

## Additional Resources

### Perses Dashboard Access
1. **Access the Dashboard:**
   - Navigate to OpenShift Console
   - Go to **Observe** → **Dashboards** (Perses)
   - Select **"Availability/Product-Registration"** from the dashboard dropdown

2. **Key Panels to Monitor for Product Registration:**
   
   **Health Status Panel:**
   - Panel: "Product Registration Health Status" (StatChart)
   - Shows: Current health status (Healthy/Unhealthy)
   - **What to check:** Should show "Healthy" with value "1"
   - **Anomaly:** If shows "UnHealthy" or value is "0", service is down

   **Error Rate Panel:**
   - Panel: "Product Registration Error Rate" (TimeSeriesChart)
   - Shows: Percentage of 5xx errors over time
   - **What to check:** Error rate should be below 5% (0.05)
   - **Anomaly:** Sustained spikes above 5% indicate service issues
   - **Legend values:** Check min, max, mean values in the table below the chart

   **Latency Panel:**
   - Panel: "Product Registration Avg. Latency" (TimeSeriesChart)
   - Shows: Average response time in milliseconds
   - **What to check:** Latency should be below 500ms
   - **Anomaly:** Sustained values above 500ms indicate performance degradation
   - **Legend values:** Monitor min, max, and mean latency values

   **Request Rate Panel:**
   - Panel: "Product Registration Request Rate" (TimeSeriesChart)
   - Shows: Number of requests per second
   - **What to check:** Monitor for unusual spikes or drops in traffic
   - **Anomaly:** Sudden drops may indicate service issues; spikes may indicate load problems
   - **Legend values:** Check min, max, mean request rates

3. **How to Identify Anomalies:**
   - **Sudden spikes:** Sharp increases in error rate or latency
   - **Sustained elevation:** Metrics staying above thresholds for extended periods
   - **Correlation:** Check if multiple panels show issues simultaneously
   - **Time correlation:** Compare with deployment times or other service issues

### Other Resources
- **Application logs:** Check centralized logging system 
- **ProductRegistrationV2 CRs:** Monitor custom resource status and events
- **Related dashboards:** Check other business services for correlated issues