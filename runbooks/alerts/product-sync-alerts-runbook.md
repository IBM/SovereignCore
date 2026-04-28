# Product Sync Alerts Runbook

## Overview
This runbook covers alerts related to business services availability and performance, including Product Sync, Product Registration, Tenant Management, and Common Service Broker.

---

## ProductSyncBackendDown

### Meaning
The HAProxy backend for Product Sync service is reporting as down (backend_up = 0).

### Impact
- Product Sync service unavailable
- Users cannot sync product data
- Critical service disruption

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="product-sync"}) by (route) == 0
   ```
2. Verify pod status in product-sync namespace:
   ```bash
   kubectl get pods -n product-sync
   ```
3. Check pod logs for errors:
   ```bash
   kubectl logs -n product-sync <pod-name>
   ```
4. Verify service endpoints:
   ```bash
   kubectl get endpoints -n product-sync
   ```

### Mitigation
1. Restart failed pods if necessary
2. Check for resource constraints (CPU/memory)
3. Review recent deployments or configuration changes
4. Verify network connectivity
5. Escalate to development team if application issue

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