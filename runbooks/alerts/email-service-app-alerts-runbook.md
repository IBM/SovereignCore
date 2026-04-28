# Email Services Alerts Runbook

## Overview
This runbook covers alerts related to business services availability and performance for the Email Service.

---

## EmailServiceAppBackendDown

### Meaning
The HAProxy backend for Email Service service is down.

### Impact
- Email Service service unavailable
- Cannot manage tenant configurations
- Multi-tenant operations disrupted

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="tenant-management"}) by (route) == 0
   ```
2. Verify pod health:
   ```bash
   kubectl get pods -n tenant-management
   kubectl describe pod -n tenant-management <pod-name>
   ```
3. Check application logs
4. Verify service dependencies
5. Check database connectivity

### Mitigation
1. Restart unhealthy pods
2. Verify configuration settings
3. Check resource availability
4. Restore database connectivity if needed
5. Review recent deployments

---

## EmailServiceAppHighErrorRate

### Meaning
Email Service service error rate has exceeded 5%.

### Impact
- Email Service failing
- Service reliability issues
- User experience degradation

### Diagnosis
1. Check error rate:
   ```promql
   sum(irate(haproxy_backend_http_responses_total{exported_namespace="tenant-management",code="5xx"}[5m])) / sum(irate(haproxy_backend_http_responses_total{exported_namespace="tenant-management"}[5m])) > 0.05
   ```
2. Analyze error logs for patterns
3. Check database performance
4. Verify service dependencies
5. Review resource utilization

### Mitigation
1. Address application errors
2. Optimize database queries if needed
3. Fix integration issues with dependencies
4. Scale application if resource-constrained
5. Implement retry logic with backoff

---

## EmailServiceAppHighLatency

### Meaning
Email Service service latency has exceeded 500ms for 10 minutes.

### Impact
- Slow tenant operations
- User experience degradation
- Potential timeout issues

### Diagnosis
1. Check latency:
   ```promql
   sum(haproxy_backend_http_average_response_latency_milliseconds{exported_namespace="tenant-management"}) by (service) > 500
   ```
2. Profile slow operations
3. Review database performance
4. Check external service response times
5. Analyze resource utilization

### Mitigation
1. Optimize slow operations
2. Implement caching where appropriate
3. Scale resources if needed
4. Optimize database queries
5. Review and tune application configuration

---

## General Troubleshooting Steps

### Check Service Health
```bash
# Check pod status
kubectl get pods -n <namespace>

# Check pod logs
kubectl logs -n <namespace> <pod-name> --tail=100

# Check pod events
kubectl describe pod -n <namespace> <pod-name>

# Check service endpoints
kubectl get endpoints -n <namespace>
```

### Check HAProxy Metrics
```bash
# View HAProxy stats
kubectl exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats

# Check backend health
kubectl exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats | grep <backend-name>
```

### Check Database Connectivity
```bash
# Test database connection from pod
kubectl exec -n <namespace> <pod-name> -- nc -zv <db-host> <db-port>

# Check database logs
kubectl logs -n <db-namespace> <db-pod-name>
```

### Resource Monitoring
```bash
# Check resource usage
kubectl top pods -n <namespace>
kubectl top nodes

# Check resource limits
kubectl describe pod -n <namespace> <pod-name> | grep -A 5 Limits
```

---

## Additional Resources
- HAProxy dashboard: Review HAProxy metrics in Grafana
- Application logs: Check centralized logging system
- Database monitoring: Review database performance dashboards
- Service mesh: Check Istio/service mesh metrics if applicable