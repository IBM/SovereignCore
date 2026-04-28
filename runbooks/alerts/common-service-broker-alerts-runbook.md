# Common Service Broker Alerts Runbook

## Overview
This runbook covers alerts related to business services availability and performance for Common Service Broker.

---

## CommonServiceBrokerBackendDown

### Meaning
The HAProxy backend for Common Service Broker is down.

### Impact
- Service broker unavailable
- Cannot provision or manage services
- Critical infrastructure component down

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="common-service-broker"}) by (route) == 0
   ```
2. Verify pod status:
   ```bash
   kubectl get pods -n common-service-broker
   ```
3. Check broker logs for errors
4. Verify API server connectivity
5. Check service catalog integration

### Mitigation
1. Restart broker pods
2. Verify RBAC permissions
3. Check API server connectivity
4. Review broker configuration
5. Verify service catalog health

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