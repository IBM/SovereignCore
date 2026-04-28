# MSP REST API Alerts Runbook

## Overview
This runbook covers alerts related to MSP (Managed Service Provider) REST API services, including UI routes, user management, and SSO services.

---

## MspUiRouteDown

### Meaning
The HAProxy backend for the MSP UI route (mspui-route) is reporting as down.

### Impact
- MSP UI unavailable to users
- Critical user-facing service disruption
- Users cannot access management console

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="sovereign-ui",route="mspui-route"}) by (route) == 0
   ```

2. Verify pod status in sovereign-ui namespace:
   ```bash
   kubectl get pods -n sovereign-ui
   kubectl describe pod -n sovereign-ui <pod-name>
   ```

3. Check pod logs:
   ```bash
   kubectl logs -n sovereign-ui <pod-name> --tail=100
   kubectl logs -n sovereign-ui <pod-name> --previous
   ```

4. Verify service and endpoints:
   ```bash
   kubectl get svc -n sovereign-ui
   kubectl get endpoints -n sovereign-ui
   kubectl describe svc -n sovereign-ui <service-name>
   ```

5. Check route configuration:
   ```bash
   kubectl get route -n sovereign-ui mspui-route
   kubectl describe route -n sovereign-ui mspui-route
   ```

### Mitigation
1. Restart failed pods:
   ```bash
   kubectl delete pod -n sovereign-ui <pod-name>
   ```

2. Check for resource constraints:
   ```bash
   kubectl top pods -n sovereign-ui
   kubectl describe pod -n sovereign-ui <pod-name> | grep -A 5 Limits
   ```

3. Verify application health endpoint:
   ```bash
   kubectl exec -n sovereign-ui <pod-name> -- curl -f http://localhost:<port>/health
   ```

4. Check for recent deployments or configuration changes:
   ```bash
   kubectl rollout history deployment -n sovereign-ui <deployment-name>
   ```

5. Review application logs for errors
6. Verify database connectivity if applicable
7. Check external dependencies (SSO, backend services)
8. Rollback deployment if recent change caused issue:
   ```bash
   kubectl rollout undo deployment -n sovereign-ui <deployment-name>
   ```

---

## MspUserManagerDown

### Meaning
The HAProxy backend for the MSP User Manager service is down.

### Impact
- User management operations unavailable
- Cannot create, update, or delete users
- Authentication/authorization issues
- Critical service disruption

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="msp-user-manager"}) by (service) == 0
   ```

2. Verify pod status:
   ```bash
   kubectl get pods -n msp-user-manager
   kubectl describe pod -n msp-user-manager <pod-name>
   ```

3. Check service logs:
   ```bash
   kubectl logs -n msp-user-manager <pod-name> --tail=100
   ```

4. Verify service endpoints:
   ```bash
   kubectl get svc -n msp-user-manager
   kubectl get endpoints -n msp-user-manager
   ```

5. Check database connectivity:
   ```bash
   kubectl exec -n msp-user-manager <pod-name> -- nc -zv <db-host> <db-port>
   ```

### Mitigation
1. Restart unhealthy pods:
   ```bash
   kubectl delete pod -n msp-user-manager <pod-name>
   ```

2. Check resource utilization:
   ```bash
   kubectl top pods -n msp-user-manager
   ```

3. Verify database connection:
   - Check database pod status
   - Verify connection credentials
   - Test database connectivity

4. Check for application errors in logs
5. Verify configuration (ConfigMaps, Secrets):
   ```bash
   kubectl get configmap -n msp-user-manager
   kubectl get secret -n msp-user-manager
   ```

6. Review recent changes and rollback if necessary
7. Scale service if resource-constrained:
   ```bash
   kubectl scale deployment -n msp-user-manager <deployment-name> --replicas=<count>
   ```

---

## SovereignSsoDown

### Meaning
The HAProxy backend for the Sovereign SSO service is down.

### Impact
- Authentication unavailable
- Users cannot log in
- Critical security service disruption
- All dependent services affected

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="msp-user-manager"}) by (service) == 0
   ```
   Note: The alert expression appears to check msp-user-manager namespace, verify correct namespace.

2. Verify SSO pod status:
   ```bash
   kubectl get pods -n <sso-namespace>
   kubectl describe pod -n <sso-namespace> <sso-pod>
   ```

3. Check SSO service logs:
   ```bash
   kubectl logs -n <sso-namespace> <sso-pod> --tail=100
   ```

4. Verify Keycloak/RHSSO status if applicable:
   ```bash
   kubectl get keycloak -A
   kubectl describe keycloak -n <namespace> <keycloak-name>
   ```

5. Check database connectivity:
   ```bash
   kubectl exec -n <sso-namespace> <sso-pod> -- nc -zv <db-host> <db-port>
   ```

### Mitigation
1. **Immediate actions:**
   - Restart SSO pods:
     ```bash
     kubectl delete pod -n <sso-namespace> <sso-pod>
     ```
   - Notify users of authentication outage

2. **Check dependencies:**
   - Verify database is running and accessible
   - Check network connectivity
   - Verify certificates are valid

3. **Review configuration:**
   ```bash
   kubectl get configmap -n <sso-namespace>
   kubectl get secret -n <sso-namespace>
   ```

4. **Check resource constraints:**
   ```bash
   kubectl top pods -n <sso-namespace>
   kubectl describe pod -n <sso-namespace> <sso-pod> | grep -A 5 Limits
   ```

5. **Verify realm configuration:**
   - Check Keycloak realm settings
   - Verify client configurations
   - Check identity provider settings

6. **Review recent changes:**
   - Check deployment history
   - Review configuration changes
   - Rollback if necessary

7. **Escalate if issue persists:**
   - Contact security team
   - Review SSO infrastructure
   - Check for certificate expiration

---

## McpHighErrorRate

### Meaning
MCP (Management Control Plane) error rate has exceeded 5% (5xx responses).

### Impact
- Service reliability degraded
- User operations failing
- Potential data integrity issues
- User experience impacted

### Diagnosis
1. Check error rate:
   ```promql
   sum by (route) (irate(haproxy_backend_http_responses_total{exported_namespace="sovereign-ui",code="5xx"}[5m])) / sum by (route) (irate(haproxy_backend_http_responses_total{exported_namespace="sovereign-ui"}[5m])) > 0.05
   ```

2. Review application logs for error patterns:
   ```bash
   kubectl logs -n sovereign-ui <pod-name> | grep -i "error\|exception\|5xx"
   ```

3. Identify specific error codes and endpoints:
   ```bash
   kubectl logs -n sovereign-ui <pod-name> --tail=1000 | grep "HTTP/1.1 5" | awk '{print $9}' | sort | uniq -c
   ```

4. Check backend service health:
   ```bash
   kubectl get pods -n sovereign-ui
   kubectl top pods -n sovereign-ui
   ```

5. Verify database connectivity and performance:
   ```bash
   kubectl exec -n sovereign-ui <pod-name> -- curl -f http://localhost:<port>/health
   ```

6. Check external service dependencies

### Mitigation
1. **Identify root cause:**
   - Review error logs for patterns
   - Check for specific failing endpoints
   - Verify database queries

2. **Fix application errors:**
   - Address bugs in code
   - Fix validation issues
   - Handle edge cases

3. **Restore dependencies:**
   - Fix database connectivity
   - Restore external service connections
   - Verify API integrations

4. **Scale resources if needed:**
   ```bash
   kubectl scale deployment -n sovereign-ui <deployment-name> --replicas=<count>
   ```

5. **Implement circuit breakers:**
   - Add timeout handling
   - Implement retry logic with backoff
   - Add fallback mechanisms

6. **Rollback if recent deployment:**
   ```bash
   kubectl rollout undo deployment -n sovereign-ui <deployment-name>
   ```

7. **Monitor recovery:**
   - Watch error rate decrease
   - Verify user operations succeed
   - Check application metrics

---

## McpHighLatency

### Meaning
MCP average response latency has exceeded 500ms for 10 minutes.

### Impact
- Poor user experience
- Slow page loads
- Potential timeout issues
- User frustration

### Diagnosis
1. Check latency metrics:
   ```promql
   sum(haproxy_backend_http_average_response_latency_milliseconds{exported_namespace=~"sovereign-ui"}) by (route) > 500
   ```

2. Identify slow endpoints:
   ```bash
   kubectl logs -n sovereign-ui <pod-name> | grep -i "slow\|latency\|duration" | tail -50
   ```

3. Check resource utilization:
   ```bash
   kubectl top pods -n sovereign-ui
   kubectl top nodes
   ```

4. Review database query performance:
   ```bash
   # Check slow queries if database metrics available
   kubectl exec -n <db-namespace> <db-pod> -- psql -c "SELECT * FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"
   ```

5. Check for external service delays:
   ```bash
   kubectl logs -n sovereign-ui <pod-name> | grep -i "timeout\|external"
   ```

6. Monitor application metrics:
   ```bash
   kubectl exec -n sovereign-ui <pod-name> -- curl localhost:<metrics-port>/metrics | grep http_request_duration
   ```

### Mitigation
1. **Optimize slow operations:**
   - Identify slow endpoints
   - Optimize database queries
   - Add database indexes
   - Implement caching

2. **Scale resources:**
   ```bash
   # Horizontal scaling
   kubectl scale deployment -n sovereign-ui <deployment-name> --replicas=<count>
   
   # Vertical scaling
   kubectl set resources deployment -n sovereign-ui <deployment-name> \
     --limits=cpu=2,memory=4Gi \
     --requests=cpu=1,memory=2Gi
   ```

3. **Implement caching:**
   - Add Redis caching layer
   - Implement HTTP caching headers
   - Cache frequently accessed data

4. **Optimize code:**
   - Profile application performance
   - Reduce N+1 queries
   - Optimize algorithms
   - Implement lazy loading

5. **Add request timeouts:**
   - Set appropriate timeouts
   - Implement circuit breakers
   - Add retry logic

6. **Review external dependencies:**
   - Optimize API calls
   - Implement parallel processing
   - Add connection pooling

7. **Monitor improvements:**
   - Track latency metrics
   - Verify user experience
   - Adjust as needed

---

## General MSP API Troubleshooting

### Check Service Health
```bash
# Check all MSP services
kubectl get pods -n sovereign-ui
kubectl get pods -n msp-user-manager

# Check service status
kubectl get svc -n sovereign-ui
kubectl get svc -n msp-user-manager

# Check routes
kubectl get route -n sovereign-ui
```

### Monitor HAProxy Metrics
```bash
# Check HAProxy stats
kubectl exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats

# Check specific backend
kubectl exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats | grep sovereign-ui
```

### Check Authentication Flow
```bash
# Test SSO endpoint
curl -v https://<sso-url>/auth/realms/<realm>/.well-known/openid-configuration

# Test user manager API
kubectl exec -n msp-user-manager <pod-name> -- curl -f http://localhost:<port>/health

# Check token validation
kubectl logs -n sovereign-ui <pod-name> | grep -i "token\|auth"
```

### Database Connectivity
```bash
# Test database connection
kubectl exec -n sovereign-ui <pod-name> -- nc -zv <db-host> <db-port>

# Check database logs
kubectl logs -n <db-namespace> <db-pod>

# Verify connection pool
kubectl logs -n sovereign-ui <pod-name> | grep -i "connection\|pool"
```

### Performance Analysis
```bash
# Check resource usage
kubectl top pods -n sovereign-ui
kubectl top pods -n msp-user-manager

# Get pod metrics
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/sovereign-ui/pods

# Check HPA if configured
kubectl get hpa -n sovereign-ui
kubectl describe hpa -n sovereign-ui <hpa-name>
```

### Log Analysis
```bash
# Export logs for analysis
kubectl logs -n sovereign-ui <pod-name> --since=1h > msp-ui-logs.txt

# Search for errors
kubectl logs -n sovereign-ui <pod-name> | grep -i "error\|exception\|failed" | tail -50

# Check access logs
kubectl logs -n sovereign-ui <pod-name> | grep "HTTP/1.1" | tail -100
```

---

## Additional Resources
- MSP Documentation: Review internal MSP documentation
- HAProxy Dashboard: Check HAProxy metrics in Grafana
- Application Logs: Review centralized logging system
- SSO/Keycloak: https://www.keycloak.org/documentation
- Monitoring Dashboard: Review MSP Grafana dashboards
- API Documentation: Review API specifications and endpoints