# Consumption Metrics Backend Alerts Runbook

## Overview
This runbook covers alerts related to Consumption Metrics Backend service availability and performance.

---

## ConsumptionMetricsBackendDown

### Meaning
The HAProxy backend for Consumption Metrics Backend service is down.

### Impact
- Consumption Metrics Backend service unavailable
- Users cannot access consumption metrics data
- Metering and billing operations disrupted
- Critical business function impacted

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="consumption-metrics-backend"}) by (route) == 0
   ```
2. Verify pod status:
   ```bash
   kubectl get pods -n consumption-metrics-backend
   ```
3. Check pod logs:
   ```bash
   kubectl logs -n consumption-metrics-backend <pod-name>
   ```
4. Check service configuration:
   ```bash
   kubectl get svc -n consumption-metrics-backend
   kubectl describe svc -n consumption-metrics-backend
   ```
5. Verify database connectivity (see Database Connectivity section below)

### Mitigation
1. Restart failed pods
2. Verify database connection settings
3. Check for resource exhaustion
4. Review application logs for errors
5. Rollback recent changes if necessary

---

## ConsumptionMetricsBackendHighErrorRate

### Meaning
Consumption Metrics Backend service is experiencing more than 5% error rate (5xx responses).

### Impact
- Service reliability degraded
- User operations failing
- Potential data integrity issues
- Metering data may not be processed correctly

### Diagnosis
1. Check error rate:
   ```promql
   sum(irate(haproxy_backend_http_responses_total{exported_namespace="consumption-metrics-backend",code="5xx"}[5m])) / sum(irate(haproxy_backend_http_responses_total{exported_namespace="consumption-metrics-backend"}[5m])) > 0.05
   ```
2. Review application logs for error patterns
3. Check database health and connectivity
4. Verify external service dependencies
5. Review recent code deployments

### Mitigation
1. Identify and fix root cause of errors
2. Rollback recent deployments if necessary
3. Restore database connectivity if needed
4. Scale resources if needed

---

## ConsumptionMetricsBackendHighLatency

### Meaning
Consumption Metrics Backend service average response latency has exceeded 500ms for 10 minutes.

### Impact
- Poor user experience
- Potential timeout issues
- Reduced throughput
- Delayed metering data processing

### Diagnosis
1. Check latency metrics:
   ```promql
   sum(haproxy_backend_http_average_response_latency_milliseconds{exported_namespace="consumption-metrics-backend"}) by (route) > 500
   ```
2. Identify slow endpoints
3. Review database query performance
4. Check for resource constraints (CPU/memory)
5. Analyze application performance metrics

### Mitigation
1. Optimize slow database queries
2. Implement caching strategies
3. Scale application resources
4. Review and optimize code paths
5. Add database indexes if needed

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check pod status
kubectl get pods -n consumption-metrics-backend

# Check pod logs
kubectl logs -n consumption-metrics-backend <pod-name> --tail=100

# Check pod events
kubectl describe pod -n consumption-metrics-backend <pod-name>

# Check service endpoints
kubectl get endpoints -n consumption-metrics-backend
```

### Check HAProxy Metrics
HAProxy runs in the `openshift-ingress` namespace as the router pods.

```bash
# List HAProxy router pods
kubectl get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default

# View HAProxy stats (replace <router-pod-name> with actual pod name from above)
kubectl exec -n openshift-ingress <router-pod-name> -- curl localhost:1936/stats

# Check backend health for consumption-metrics-backend
kubectl exec -n openshift-ingress <router-pod-name> -- curl localhost:1936/stats | grep consumption-metrics-backend
```

**Note:** Router pod names follow the pattern `router-default-<hash>-<hash>`. Use the first command to get current pod names.

### Check Database Connectivity
```bash
# Test database connection from pod
kubectl exec -n consumption-metrics-backend <pod-name> -- nc -zv <db-host> <db-port>

# Check database logs
kubectl logs -n <db-namespace> <db-pod-name>

# Verify database credentials secret
kubectl get secret -n consumption-metrics-backend | grep db

# Check database connection from application
kubectl exec -n consumption-metrics-backend <pod-name> -- env | grep -i db
```

### Database Performance Monitoring
```bash
# Check database pod status
kubectl get pods -n <db-namespace>

# Check database resource usage
kubectl top pods -n <db-namespace>

# Check database connections
kubectl exec -n <db-namespace> <postgres-pod> -- psql -U <username> -d <database> -c "SELECT count(*) FROM pg_stat_activity;"

# Check slow queries
kubectl exec -n <db-namespace> <postgres-pod> -- psql -U <username> -d <database> -c "SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"
```

### Resource Monitoring
```bash
# Check resource usage
kubectl top pods -n consumption-metrics-backend
kubectl top nodes

# Check resource limits
kubectl describe pod -n consumption-metrics-backend <pod-name> | grep -A 5 Limits

# Check HPA status (if configured)
kubectl get hpa -n consumption-metrics-backend
```

### Check External Service Connectivity
```bash
# Test connectivity to external endpoints
kubectl exec -n consumption-metrics-backend <pod-name> -- curl -v <external-endpoint>

# Check network policies
kubectl get networkpolicies -n consumption-metrics-backend
```

---

## Additional Resources

### Perses Dashboard Access
1. **Access the Dashboard:**
   - Navigate to OpenShift Console
   - Go to **Observe** → **Dashboards** (Perses)
   - Select **"Availability/Consumption-Metrics-Backend"** from the dashboard dropdown

2. **Key Panels to Monitor for Consumption Metrics Backend:**
   
   **Health Status Panel:**
   - Panel: "Consumption Metrics Backend Health Status" (StatChart)
   - Shows: Current health status (Healthy/Unhealthy)
   - **What to check:** Should show "Healthy" with value "1"
   - **Anomaly:** If shows "UnHealthy" or value is "0", service is down

   **Error Rate Panel:**
   - Panel: "Consumption Metrics Backend Error Rate" (TimeSeriesChart)
   - Shows: Percentage of 5xx errors over time
   - **What to check:** Error rate should be below 5% (0.05)
   - **Anomaly:** Sustained spikes above 5% indicate service issues
   - **Legend values:** Check min, max, mean values in the table below the chart

   **Latency Panel:**
   - Panel: "Consumption Metrics Backend Avg. Latency" (TimeSeriesChart)
   - Shows: Average response time in milliseconds
   - **What to check:** Latency should be below 500ms
   - **Anomaly:** Sustained values above 500ms indicate performance degradation
   - **Legend values:** Monitor min, max, and mean latency values

   **Request Rate Panel:**
   - Panel: "Consumption Metrics Backend Request Rate" (TimeSeriesChart)
   - Shows: Number of requests per second
   - **What to check:** Monitor for unusual spikes or drops in traffic
   - **Anomaly:** Sudden drops may indicate service issues; spikes may indicate load problems
   - **Legend values:** Check min, max, mean request rates

3. **How to Identify Anomalies:**
   - **Sudden spikes:** Sharp increases in error rate or latency
   - **Sustained elevation:** Metrics staying above thresholds for extended periods
   - **Correlation:** Check if multiple panels show issues simultaneously
   - **Time correlation:** Compare with deployment times or other service issues
   - **Database correlation:** Check if database performance issues coincide with service degradation

### Other Resources
- **Application logs:** Check centralized logging system
- **Database monitoring:** Review database performance dashboards
- **Database connection pool:** Monitor connection pool metrics
- **Related dashboards:** Check other business services for correlated issues